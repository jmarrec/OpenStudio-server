class Analysis
  include Mongoid::Document
  include Mongoid::Timestamps
  include Mongoid::Paperclip

  require 'delayed_job_mongoid'

  field :uuid, :type => String
  field :_id, :type => String, default: -> { uuid || UUID.generate }
  field :version_uuid
  field :name, :type => String
  field :display_name, :type => String
  field :description, :type => String
  field :run_flag, :type => Boolean
  field :delayed_job_id # ObjectId
  field :status, :type => String # enum on the status of the analysis (queued, started, completed)
  field :analysis_type, :type => String
  field :analysis_output, :type => Array
  field :start_time, :type => DateTime
  field :end_time, :type => DateTime
  field :os_metadata # don't define type, keep this flexible
  field :use_shm, :type => Boolean, default: false #flag on whether or not to use SHM for analysis (impacts file uploading)

  has_mongoid_attached_file :seed_zip,
                            :url => "/assets/analyses/:id/:style/:basename.:extension",
                            :path => ":rails_root/public/assets/analyses/:id/:style/:basename.:extension"

  # Relationships
  belongs_to :project
  has_many :data_points
  has_many :algorithms
  has_many :variables # right now only having this a one-to-many (ideally this can go both ways)
  has_many :measures
  #has_many :problems

  # Indexes
  index({uuid: 1}, unique: true)
  index({id: 1}, unique: true)
  index({name: 1}, unique: true)
  index({project_id: 1})
  index({uuid: 1, status: 1})
  index({uuid: 1, download_status: 1})

  # Validations
  # validates_format_of :uuid, :with => /[^0-]+/
  # validates_attachment :seed_zip, content_type: { content_type: "application/zip" }

  # Callbacks
  after_create :verify_uuid
  before_destroy :remove_dependencies

  def initialize_workers
    # delete the master and workers and reload them
    MasterNode.delete_all
    WorkerNode.delete_all

    # load in the master and worker information if it doesn't already exist
    ip_file = "/home/ubuntu/ip_addresses"
    if !File.exists?(ip_file)
      ip_file = "/data/launch-instance/ip_addresses" # somehow check if this is a vagrant box -- RAILS ENV?
    end

    ips = File.read(ip_file).split("\n")
    ips.each do |ip|
      cols = ip.split("|")
      if cols[0] == "master"
        mn = MasterNode.find_or_create_by(:ip_address => cols[1])
        mn.hostname = cols[2]
        mn.cores = cols[3]
        mn.user = cols[4]
        mn.password = cols[5].chomp

        mn.save!

        logger.info("Master node #{mn.inspect}")
      elsif cols[0] == "worker"
        wn = WorkerNode.find_or_create_by(:ip_address => cols[1])
        wn.hostname = cols[2]
        wn.cores = cols[3]
        wn.user = cols[4]
        wn.password = cols[5].chomp
        wn.valid = false
        if cols[6] && cols[6].chomp == "true"
          wn.valid = true
        end
        wn.save!

        logger.info("Worker node #{wn.inspect}")
      end
    end

    # get server and worker characteristics
    get_system_information()

    # check if this fails
    copy_data_to_workers()
  end


  def start(no_delay, analysis_type='batch_run')
    Rails.logger.info("Starting #{analysis_type}")

    # get the data points that are going to be run
    data_points_hash = {}
    data_points_hash[:data_points] = []
    self.data_points.all.each do |dp|
      dp.status = 'queued'
      dp.save!
      data_points_hash[:data_points] << dp.uuid
    end
    Rails.logger.info(data_points_hash)

    if no_delay
      abr = "Analysis::#{analysis_type.camelize}".constantize.new(self.id, data_points_hash)
      abr.perform
    else
      job = Delayed::Job.enqueue "Analysis::#{analysis_type.camelize}".constantize.new(self.id, data_points_hash), :queue => 'analysis'
      self.delayed_job_id = job.id
      self.save!
    end
  end

  def run_analysis(no_delay = false, analysis_type = 'batch_run')
    # check if there is already an analysis in the queue (this needs to move to the analysis class)
    # there is no reason why more than one analyses can be queued at the same time.
    Rails.logger.info("running R analysis with #{analysis_type}")

    self.delayed_job_id.nil? ? dj = nil : dj = Delayed::Job.find(self.delayed_job_id)

    if dj || self.status == "queued" || self.status == "started"
      logger.info("analysis is already queued with #{dj}")
      return [false, "An analysis is already queued"]
    else
      # NL: I would like to move this inside the queued analysis piece. I think
      # we could have an issue if there are many worker nodes and this method times out.
      self.start_time = Time.now

      logger.info("Initializing workers in database")
      self.initialize_workers

      logger.info("queuing up analysis #{@analysis}")
      self.analysis_type = analysis_type
      self.status = 'queued'
      self.save!

      self.start(no_delay, analysis_type)

      return [true]
    end
  end

  def stop_analysis
    logger.info("stopping analysis")
    self.run_flag = false
    self.status = 'completed'
    self.save!
  end

  def pull_out_os_variables
    # get the measures first
    Rails.logger.info("pulling out openstudio measures")
    # note the measures first
    if self['problem'] && self['problem']['workflow']
      Rails.logger.info("found a problem and workflow")
      self['problem']['workflow'].each do |wf|
        # this will eventually need to be cleaned up, but the workflow is the order of applying the
        # individual measures
        if wf['measures']
          wf['measures'].each do |measure|
            new_measure = Measure.create_from_os_json(self.id, measure)
          end
        end
      end
    end

    #Rails.logger.error("OpenStudio Metadata is: #{self.os_metadata}")
    if self.os_metadata && self.os_metadata['variables']
      self.os_metadata['variables'].each do |variable|
        var = Variable.create_from_os_json(self.id, variable)
      end
    end
    self.save!
  end

  # copy back the results to the master node if they are finished
  def download_data_from_workers
    any_downloaded = false
    self.data_points.and({download_status: 'na'}, {status: 'completed'}).each do |dp|
      downloaded = dp.download_datapoint_from_worker
      any_downloaded = any_downloaded || downloaded
    end
    return any_downloaded
  end

  protected

  def remove_dependencies
    logger.info("Found #{self.data_points.size} records")
    self.data_points.each do |record|
      logger.info("removing #{record.id}")
      record.destroy
    end

    logger.info("Found #{self.algorithms.size} records")
    self.algorithms.each do |record|
      logger.info("removing #{record.id}")
      record.destroy
    end

    logger.info("Found #{self.measures.size} records")
    if self.measures
      self.measures.each do |record|
        logger.info("removing #{record.id}")
        record.destroy
      end
    end

    logger.info("Found #{self.variables.size} records")
    if self.variables
      self.variables.each do |record|
        logger.info("removing #{record.id}")
        record.destroy
      end
    end

    # delete any delayed jobs items
    if self.delayed_job_id
      dj = Delayed::Job.find(self.delayed_job_id)
      dj.delete unless dj.nil?
    end
  end

  def verify_uuid
    self.uuid = self.id if self.uuid.nil?
    self.save!
  end

  private

  # copy the zip file over the various workers and extract the file.
  # if the file already exists, then it will overwrite the file
  # verify the behaviour of the zip extraction on top of an already existing analysis.
  def copy_data_to_workers
    # copy the datafiles over to the worker nodes
    WorkerNode.all.each do |wn|
      Net::SSH.start(wn.ip_address, wn.user, :password => wn.password) do |session|
        logger.info(self.inspect)
        if !use_shm
          upload_dir = "/mnt/openstudio"
          session.scp.upload!(self.seed_zip.path, "#{upload_dir}/")

          session.exec!("cd #{upload_dir} && unzip -o #{self.seed_zip_file_name}") do |channel, stream, data|
            logger.info(data)
          end
          session.loop
        else
          upload_dir = "/run/shm/openstudio"
          storage_dir = "/mnt/openstudio"
          session.exec!("rm -rf #{upload_dir}") do |channel, stream, data|
            Rails.logger.info(data)
          end
          session.loop

          session.exec!("rm -f #{storage_dir}/*.log && rm -rf #{storage_dir}/analysis") do |channel, stream, data|
            Rails.logger.info(data)
          end
          session.loop

          session.exec!("mkdir -p #{upload_dir}") do |channel, stream, data|
            Rails.logger.info(data)
          end
          session.loop

          session.scp.upload!(self.seed_zip.path, "#{upload_dir}")

          session.exec!("cd #{upload_dir} && unzip -o #{self.seed_zip_file_name} && chmod -R 775 #{upload_dir}") do |channel, stream, data|
            logger.info(data)
          end
          session.loop
        end
      end
    end
  end

  # During the initialization of each analysis, go to each system node and grab its information
  def get_system_information
    #if Rails.env == "development"  #eventually set this up to be the flag to switch between varying environments

    #end

    Socket.gethostname =~ /os-.*/ ? local_host = true : local_host = false

    # For now assume that there is only one master node
    mn = MasterNode.first
    if mn
      if local_host
        mn.ami_id = "Vagrant"
        mn.instance_id = "Vagrant"
      else # must be on amazon -- hit the api for the answers
        mn.ami_id = `curl -L http://169.254.169.254/latest/meta-data/ami-id`
        mn.instance_id = `curl -L http://169.254.169.254/latest/meta-data/instance-id`
      end
      mn.save!
    end

    # go through the worker node
    WorkerNode.all.each do |wn|
      if local_host
        wn.ami_id = "Vagrant"
        wn.instance_id = "Vagrant"
      else
        # have to communicate with the box to get the instance information (ideally this gets pushed from who knew)
        Net::SSH.start(wn.ip_address, wn.user, :password => wn.password) do |session|
          #Rails.logger.info(self.inspect)

          logger.info "Checking the configuration of the worker nodes"
          session.exec!("curl -L http://169.254.169.254/latest/meta-data/ami-id") do |channel, stream, data|
            Rails.logger.info("Worker node reported back #{data}")
            wn.ami_id = data
          end
          session.loop

          session.exec!("curl -L http://169.254.169.254/latest/meta-data/instance-id") do |channel, stream, data|
            Rails.logger.info("Worker node reported back #{data}")
            wn.instance_id = data
          end
          session.loop
        end
      end

      wn.save!
    end
  end
end
