# *******************************************************************************
# OpenStudio(R), Copyright (c) 2008-2016, Alliance for Sustainable Energy, LLC.
# All rights reserved.
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# (1) Redistributions of source code must retain the above copyright notice,
# this list of conditions and the following disclaimer.
#
# (2) Redistributions in binary form must reproduce the above copyright notice,
# this list of conditions and the following disclaimer in the documentation
# and/or other materials provided with the distribution.
#
# (3) Neither the name of the copyright holder nor the names of any contributors
# may be used to endorse or promote products derived from this software without
# specific prior written permission from the respective party.
#
# (4) Other than as required in clauses (1) and (2), distributions in any form
# of modifications or other derivative works may not use the "OpenStudio"
# trademark, "OS", "os", or any other confusingly similar designation without
# specific prior written permission from Alliance for Sustainable Energy, LLC.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER, THE UNITED STATES
# GOVERNMENT, OR ANY CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
# INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
# LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
# PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
# LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
# NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
# EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
# *******************************************************************************

require 'rails_helper'

RSpec.describe RunSimulateDataPoint, type: :feature do
  before :each do
    # Look at DatabaseCleaner gem in the future to deal with this.
    Project.destroy_all
    DataPoint.destroy_all  # this really isn't needed, but is here to deal with data points that aren't attached to analyses
    Delayed::Job.destroy_all
    ComputeNode.destroy_all

    # I am no longer using this factory for this purpose. It doesn't
    # link up everything, so just post the test using the Analysis Gem.
    #  FactoryGirl.create(:project_with_analyses).analyses
  end

  it 'should create the datapoint', js: true do
    host = "#{Capybara.current_session.server.host}:#{Capybara.current_session.server.port}"
    puts "App host is: #{host}"

    # TODO: Make this a helper of some sort
    options = { hostname: "http://#{host}" }
    api = OpenStudio::Analysis::ServerApi.new(options)
    project_id = api.new_project
    expect(project_id).not_to be nil
    analysis_options = {
      formulation_file: 'spec/files/batch_datapoints/example_csv.json',
      upload_file: 'spec/files/batch_datapoints/example_csv.zip'
    }
    analysis_id = api.new_analysis(project_id, analysis_options)

    puts analysis_id
    expect(analysis_id).not_to be nil

    a = RestClient.get "http://#{host}/analyses/#{analysis_id}.json"

    # expect(...something...)

    # Go set the r_index of the variables because the algorithm normally
    # sets the index
    selected_variables = Variable.variables(analysis_id)
    selected_variables.each_with_index do |v, index|
      v.r_index = index + 1
      v.save
    end

    expect(selected_variables.size).to eq 2
    data_point_data = {
      data_point: {
        name: 'API Test Datapoint',
        ordered_variable_values: [1, 1]
      }
    }

    a = RestClient.post "http://#{host}/analyses/#{analysis_id}/data_points.json", data_point_data
    a = JSON.parse(a, symbolize_names: true)
    expect(a[:set_variable_values].size).to eq 2
    expect(a[:set_variable_values].values[0]).to eq 1.0
    expect(a[:set_variable_values].values[1]).to eq 1.0
    # expect(a[:set_variable_values].values[2]).to eq 5
    # expect(a[:set_variable_values].values[3]).to eq 20
    # expect(a[:set_variable_values].values[4]).to eq "*Entire Building*"

    expect(a[:_id]).to match /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/

    a = RestClient.get "http://#{host}/analyses/#{analysis_id}/status.json"
    a = JSON.parse(a, symbolize_names: true)
    expect(a[:analysis][:data_points].size).to eq 1

    # test using the script
    script = File.expand_path('../docker/R/api_create_datapoint.rb', Rails.root)
    puts script
  end

  it 'should run a datapoint', js: true do
    host = "#{Capybara.current_session.server.host}:#{Capybara.current_session.server.port}"
    # Set the os server url for use by the run simulation
    APP_CONFIG['os_server_host_url'] = "http://#{host}"

    # TODO: Make this a helper of some sort
    options = { hostname: "http://#{host}" }
    api = OpenStudio::Analysis::ServerApi.new(options)
    project_id = api.new_project
    expect(project_id).not_to be nil
    analysis_options = {
      formulation_file: 'spec/files/batch_datapoints/example_csv.json',
      upload_file: 'spec/files/batch_datapoints/example_csv.zip'
    }
    analysis_id = api.new_analysis(project_id, analysis_options)
    dp_file = 'spec/files/batch_datapoints/example_data_point_1.json'
    dp_json = api.upload_datapoint(analysis_id, datapoint_file: dp_file)
    expect(Delayed::Job.count).to eq(0)

    dp = DataPoint.find(dp_json[:_id])
    datapoint_id = dp.id
    job_id = dp.submit_simulation
    expect(job_id).to match /.{24}/
    expect(dp.id).to match /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/
    expect(dp.analysis.id).to eq analysis_id
    expect(Delayed::Job.count).to eq(1)

    # Start the work
    work_result = nil
    t = Thread.new do
      work_result = Delayed::Worker.new.work_off
    end
    t.run

    while t.status
      # get the analysis status as json
      a = RestClient.get "http://#{host}/analyses/#{analysis_id}/status.json"
      a = JSON.parse(a, symbolize_names: true)
      expect(a[:analysis][:data_points].size).to eq 1
      # puts "accessed http://#{host}/analyses/#{analysis_id}/status.json"

      # get the analysis as html
      a = RestClient.get "http://#{host}/analyses/#{analysis_id}.html"
      # puts "accessed http://#{host}/analyses/#{analysis_id}.html"

      # get the datapoint as json
      a = RestClient.get "http://#{host}/data_points/#{datapoint_id}.json"
      a = JSON.parse(a, symbolize_names: true)
      # puts "accessed http://#{host}/data_points/#{datapoint_id}.json"

      # get the datapoint as html
      a = RestClient.get "http://#{host}/data_points/#{datapoint_id}.html"
      puts "accessed http://#{host}/data_points/#{datapoint_id}.html"

      # slow down the access to the datapoint
      sleep(0.5)
    end
    t.join

    expect(work_result).to eq [1, 0] # expects 1 success and 0 failures
    expect(Delayed::Job.count).to eq(0)

    # Verify that the results exist
    j = api.get_analysis_results(analysis_id)
    expect(j).to be_a Hash
    expect(j[:data]).to be_an Array

    # verify that the data point has a log
    j = api.get_datapoint(datapoint_id)
    puts JSON.pretty_generate(j)
    expect(j[:data_point][:sdp_log_file]).not_to be_empty

    # TODO: Check results -- may need different analysis type with annual data
  end

  it 'should create a write lock that is threadsafe' do
    # okay, threadsafe is a misnomer here -- is this really thread safe?
    # if it downloads it twice, then okay, but 100 times, ughly.

    dp = DataPoint.new
    dp.save!
    a = RunSimulateDataPoint.new(dp.id)
    write_lock_file = 'spec/files/tmp/write.lock'
    receipt_file = 'spec/files/tmp/write.receipt'
    FileUtils.mkdir_p 'spec/files/tmp'
    File.delete(write_lock_file) if File.exist? write_lock_file
    File.delete(receipt_file) if File.exist? receipt_file

    thread_count = 500
    arr = Array.new(thread_count)
    puts arr.inspect
    Parallel.each(0..thread_count, in_threads: thread_count) do |index|
      arr[index] = 0 if File.exist? receipt_file

      # TODO: Break this code out into its own class and test it there
      if File.exist? write_lock_file
        # wait until receipt file appears then return
        loop do
          break if File.exist? receipt_file
          sleep 1
        end

        arr[index] = 0
      else
        a.write_lock(write_lock_file) do |_|
          puts "Downloading for index #{index}..."
          arr[index] = 1
          sleep 3
        end
      end
      File.open(receipt_file, 'w') { |f| f << Time.now }
    end

    puts arr.inspect
    expect(arr.sum).to be < 5
  end

  it 'should sort worker jobs correctly' do
    a = %w(00_Job0 01_Job1 11_Job11 20_Job20 02_Job2 21_Job21)

    a.sort!

    expect(a.first).to eq '00_Job0'
    expect(a.last).to eq '21_Job21'
    expect(a[3]).to eq '11_Job11'
  end

  it 'should not step on datapoints', js: true do
    host = "#{Capybara.current_session.server.host}:#{Capybara.current_session.server.port}"
    # Set the os server url for use by the run simulation
    APP_CONFIG['os_server_host_url'] = "http://#{host}"

    # TODO: Make this a helper of some sort
    options = { hostname: "http://#{host}" }
    api = OpenStudio::Analysis::ServerApi.new(options)
    project_id = api.new_project
    expect(project_id).not_to be nil
    analysis_options = {
        formulation_file: 'spec/files/batch_datapoints/example_csv.json',
        upload_file: 'spec/files/batch_datapoints/example_csv.zip'
    }
    analysis_id = api.new_analysis(project_id, analysis_options)

    # Start the workers first, wheee
    n_workers = 2
    (0..n_workers-1).to_a.each do |i_worker|
      command = "bundle exec bin/delayed_job -i worker_#{i_worker} --queues=test run --log-dir=log --pid-dir tmp/pids"
      puts "Starting worker with command #{command}"
      spawn(command, [:err, :out] => ["log/dj_worker_#{i_worker}.log", 'w'])
    end

    thread_watch = Thread.new do
      while true
        dp_na = DataPoint.where(analysis_id: analysis_id, status: :na).count
        dp_queued = DataPoint.where(analysis_id: analysis_id, status: :queued).count
        dp_started = DataPoint.where(analysis_id: analysis_id, status: :started).count
        dp_completed = DataPoint.where(analysis_id: analysis_id, status: :completed).count

        puts "na: #{dp_na}, queued: #{dp_queued}, started: #{dp_started}, completed: #{dp_completed}"
        sleep 0.49
      end
    end.run

    expect(Delayed::Job.count).to eq(0)
    analysis = Analysis.find(analysis_id)
    # create n number of simulations
    n = n_workers * 10
    (0..n-1).to_a.each do |i|
      puts "creating datapoint for #{i}" if i % 1000 == 0
      dp = analysis.data_points.new(analysis_id: analysis_id, name: "Test #{n}")
      dp.save!

      dp.submit_simulation(TestWorker, 'test')
    end

    while Delayed::Job.count > 0
      sleep 5
    end

    expect(DataPoint.where(analysis_id: analysis_id ).count).to eq n
    expect(Delayed::Job.count).to eq(0)

    thread_watch.exit
  end


  after :each do
    Delayed::Job.destroy_all
    # Project.destroy_all
    # kill all the pids that may be running
  end
end
