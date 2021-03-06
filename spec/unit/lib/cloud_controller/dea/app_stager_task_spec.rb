require "spec_helper"

module VCAP::CloudController
  describe Dea::AppStagerTask do
    let(:message_bus) { CfMessageBus::MockMessageBus.new }
    let(:stager_pool) { double(:stager_pool, :reserve_app_memory => nil) }
    let(:dea_pool) { double(:stager_pool, :reserve_app_memory => nil) }
    let(:config_hash) { { staging: { timeout_in_seconds: 360 } } }
    let(:app) do
      AppFactory.make(
        :package_hash => "abc",
        :droplet_hash => nil,
        :package_state => "PENDING",
        :state => "STARTED",
        :instances => 1,
        :disk_quota => 1024
      )
    end
    let(:stager_id) { "my_stager" }
    let(:blobstore_url_generator) { CloudController::DependencyLocator.instance.blobstore_url_generator }

    let(:options) { {} }
    subject(:staging_task) { Dea::AppStagerTask.new(config_hash, message_bus, app, dea_pool, stager_pool, blobstore_url_generator) }

    let(:first_reply_json_error) { nil }
    let(:task_streaming_log_url) { "task-streaming-log-url" }

    let(:first_reply_json) do
      {
        "task_id" => "task-id",
        "task_log" => "task-log",
        "task_streaming_log_url" => task_streaming_log_url,
        "detected_buildpack" => nil,
        "detected_start_command" => nil,
        "buildpack_key" => nil,
        "error" => first_reply_json_error,
        "droplet_sha1" => nil
      }
    end

    let(:reply_json_error) { nil }
    let(:reply_error_info) { nil }
    let(:detected_buildpack) { nil }
    let(:detected_start_command) { "wait_for_godot" }
    let(:buildpack_key) { nil }

    let(:reply_json) do
      {
        "task_id" => "task-id",
        "task_log" => "task-log",
        "task_streaming_log_url" => nil,
        "detected_buildpack" => detected_buildpack,
        "buildpack_key" => buildpack_key,
        "detected_start_command" => detected_start_command,
        "error" => reply_json_error,
        "error_info" => reply_error_info,
        "droplet_sha1" => "droplet-sha1"
      }
    end

    before do
      expect(app.staged?).to be false

      allow(VCAP).to receive(:secure_uuid) { "some_task_id" }
      allow(stager_pool).to receive(:find_stager).with(app.stack.name, 1024, anything).and_return(stager_id)

      allow(EM).to receive(:add_timer)
      allow(EM).to receive(:defer).and_yield
      allow(EM).to receive(:schedule_sync)
    end

    context 'when no stager can be found' do
      let(:stager_id) { nil }

      it 'should raise an error' do
        expect {
          staging_task.stage
        }.to raise_error(Errors::ApiError, /no available stagers/)
      end
    end

    context 'when a stager can be found' do
      it 'should stop other staging tasks' do
        expect(message_bus).to receive(:publish).with("staging.stop", hash_including({ :app_id => app.guid }))
        staging_task.stage
      end
    end

    describe "staging memory requirements" do
      context 'when the app memory requirement exceeds the staging memory requirement (1024)' do
        it 'should request a stager with the app memory requirement' do
          app.memory = 1025
          expect(stager_pool).to receive(:find_stager).with(app.stack.name, 1025, anything).and_return(stager_id)
          staging_task.stage
        end
      end

      context 'when the app memory requirement is less than the staging memory requirement' do
        it "requests the staging memory requirement" do
          config_hash[:staging][:minimum_staging_memory_mb] = 2048
          expect(stager_pool).to receive(:find_stager).with(app.stack.name, 2048, anything).and_return(stager_id)
          staging_task.stage
        end
      end
    end

    describe "staging disk requirements" do
      context 'when the app disk requirement is less than the staging disk requirement' do
        it "should request a stager with enough disk" do
          app.disk_quota = 12
          config_hash[:staging][:minimum_staging_disk_mb] = 1025
          expect(stager_pool).to receive(:find_stager).with(app.stack.name, anything, 1025).and_return(stager_id)
          staging_task.stage
        end
      end

      context 'when the app disk requirement is less than the default (4096) staging disk requirement, and it wasnt overridden' do
        it "should request a stager with enough disk" do
          app.disk_quota = 123
          config_hash[:staging][:minimum_staging_disk_mb] = nil
          expect(stager_pool).to receive(:find_stager).with(app.stack.name, anything, 4096).and_return(stager_id)
          staging_task.stage
        end
      end

      context 'when the app disk requirement exceeds the staging disk requirement' do
        it "should request a stager with enough disk" do
          app.disk_quota = 123
          config_hash[:staging][:minimum_staging_disk_mb] = 122
          expect(stager_pool).to receive(:find_stager).with(app.stack.name, anything, 123).and_return(stager_id)
          staging_task.stage
        end
      end
    end

    describe "staging" do
      describe "receiving the first response from the stager (the staging setup completion message)" do
        def stage(&blk)
          stub_schedule_sync do
            @before_staging_completion.call if @before_staging_completion
            message_bus.respond_to_request("staging.#{stager_id}.start", first_reply_json)
          end

          response = staging_task.stage(&blk)
          response
        end

        context "when staging setup succeeds" do
          it "returns streaming log url and rest will happen asynchronously" do
            expect(stage.streaming_log_url).to eq("task-streaming-log-url")
          end

          it "leaves the app as not having been staged" do
            stage
            expect(app).to be_pending
          end

          context "when there are available stagers" do
            it "stops other staging tasks and starts a new one" do
              expect(message_bus).to receive(:publish).with("staging.stop", anything)
              expect(message_bus).to receive(:publish).with("staging.my_stager.start", staging_task.staging_request)

              stage
            end

            it "saves staging task id" do
              stage
              expect(app.staging_task_id).to eq("some_task_id")
            end
          end
          it "keeps the app as not staged" do
            expect { stage }.to_not change { app.staged? }.from(false)
          end

          it "does not save the detected start command" do
            expect { stage }.to_not change { app.detected_start_command }.from('')
          end

          it "does not save the detected buildpack" do
            expect { stage }.to_not change { app.detected_buildpack }.from(nil)
          end

          it "does not save the detected buildpack guid" do
            expect { stage }.to_not change { app.detected_buildpack_guid }.from(nil)
          end

          it "does not call provided callback (not yet)" do
            callback_called = false
            stage { callback_called = true }
            expect(callback_called).to be false
          end
        end

        context "when staging setup fails without a reason" do
          let(:first_reply_json) { 'invalid-json' }

          it "raises a StagingError" do
            expect { stage }.to raise_error(Errors::ApiError, /failed to stage/)
          end

          it "keeps the app as not staged" do
            expect {
              ignore_staging_error { stage }
            }.to_not change { app.staged? }.from(false)
          end

          it "does not save the detected buildpack" do
            expect {
              ignore_staging_error { stage }
            }.to_not change { app.detected_buildpack }.from(nil)
          end

          it "does not save the detected buildpack guid" do
            expect {
              ignore_staging_error {stage }
            }.to_not change { app.detected_buildpack_guid }.from(nil)
          end

          it "does not save the detected start command" do
            expect {
              ignore_staging_error { stage }
            }.to_not change { app.detected_start_command }.from('')
          end

          it "does not call provided callback (not yet)" do
            callback_called = false
            ignore_staging_error { stage { callback_called = true } }
            expect(callback_called).to be false
          end

          it "marks the app as having failed to stage" do
            expect { ignore_staging_error { stage } }.to change { app.staging_failed? }.to(true)
          end
        end

        context "when staging setup returned an error response" do
          let(:first_reply_json_error) { "staging failed" }

          it "raises a StagingError" do
            expect { stage }.to raise_error(Errors::ApiError, /failed to stage/)
          end

          it "keeps the app as not staged" do
            expect { ignore_staging_error { stage } }.to_not change { app.staged? }.from(false)
          end

          it "does not save the detected buildpack" do
            expect { ignore_staging_error { stage } }.to_not change { app.detected_buildpack }.from(nil)
          end

          it "does not save the detected buildpack guid" do
            expect {
              ignore_staging_error { stage }
            }.to_not change { app.detected_buildpack_guid }.from(nil)
          end

          it "does not save the detected start command" do
            expect { ignore_staging_error { stage } }.to_not change { app.detected_start_command }.from('')
          end

          it "does not call provided callback (not yet)" do
            callback_called = false
            ignore_staging_error { stage { callback_called = true } }
            expect(callback_called).to be false
          end

          it "marks the app as having failed to stage" do
            expect { ignore_staging_error { stage } }.to change { app.staging_failed? }.to(true)
          end
        end

        context "when an exception occurs" do
          def reply_with_staging_completion
            message_bus.respond_to_request("staging.#{stager_id}.start", {})
          end

          it "copes when the app is destroyed halfway between staging (currently we dont know why this happened but seen on tabasco)" do
            allow(VCAP::CloudController::Dea::AppStagerTask::Response).to receive(:new) do
              app.destroy # We saw that app maybe destroyed half-way through staging
              raise ArgumentError, "Some Fake Error"
            end

            expect { stage }.to raise_error ArgumentError, "Some Fake Error"
          end
        end
      end

      describe "receiving staging completion message" do
        def stage(&blk)
          stub_schedule_sync do
            @before_staging_completion.call if @before_staging_completion
            message_bus.respond_to_request("staging.#{stager_id}.start", first_reply_json)
          end

          staging_task.stage(&blk)
          message_bus.respond_to_request("staging.#{stager_id}.start", reply_json)
        end

        context "when app staging succeeds" do
          let(:detected_buildpack) { "buildpack detect output" }

          context "when no other staging has happened" do
            before do
              allow(dea_pool).to receive(:mark_app_started)
            end

            it "marks the app as staged" do
              expect { stage }.to change { app.refresh.staged? }.to(true)
            end

            it "saves the detected buildpack" do
              expect { stage }.to change { app.refresh.detected_buildpack }.from(nil)
            end

            context "and the droplet has been uploaded" do
              it "saves the detected start command" do
                app.droplet_hash = "Abc"
                expect { stage }.to change {
                  app.current_droplet.refresh
                  app.detected_start_command
                }.from('').to("wait_for_godot")
              end
            end

            context "when the droplet somehow has not been uploaded (defensive)" do
              it "does not change the start command" do
                expect { stage }.not_to change {
                  app.detected_start_command
                }.from('')
              end
            end

            context "when detected_start_command is not returned" do
              let(:reply_json) do
                {
                  "task_id" => "task-id",
                  "task_log" => "task-log",
                  "task_streaming_log_url" => nil,
                  "detected_buildpack" => detected_buildpack,
                  "buildpack_key" => buildpack_key,
                  "error" => reply_json_error,
                  "error_info" => reply_error_info,
                  "droplet_sha1" => "droplet-sha1"
                }
              end

              it "does not change the detected start command" do
                app.droplet_hash = "Abc"
                expect { stage }.not_to change {
                  app.current_droplet.refresh
                  app.detected_start_command
                }.from('')
              end
            end

            context "when an admin buildpack is used" do
              let(:admin_buildpack) { Buildpack.make(name: "buildpack-name") }
              let(:buildpack_key) { admin_buildpack.key }
              before do
                app.buildpack = admin_buildpack.name
              end

              it "saves the detected buildpack guid" do
                expect { stage }.to change { app.refresh.detected_buildpack_guid }.from(nil)
              end
            end

            it "does not clobber other attributes that changed between staging" do
              # fake out the app refresh as the race happens after it
              allow(app).to receive(:refresh)

              other_app_ref = App.find(guid: app.guid)
              other_app_ref.command = "some other command"
              other_app_ref.save

              expect { stage }.to_not change {
                other_app_ref.refresh.command
              }
            end

            it "marks app started in dea pool" do
              expect(dea_pool).to receive(:mark_app_started).with({:dea_id => stager_id, :app_id => app.guid})
              stage
            end

            it "calls provided callback" do
              callback_options = nil
              stage { |options| callback_options = options }
              expect(callback_options[:started_instances]).to equal(1)
            end
          end

          context "when other staging has happened" do
            before do
              @before_staging_completion = -> {
                app.staging_task_id = "another-staging-task-id"
                app.save
              }
            end

            it "does not mark the app as staged" do
              expect { stage rescue nil }.not_to change { app.refresh.staged? }
            end

            it "raises a StagingError" do
              expect {
                stage
              }.to raise_error(
                       Errors::ApiError,
                       /another staging request was initiated/
                   )
            end

            it "does not update droplet hash on the app" do
              expect {
                ignore_staging_error { stage }
              }.to_not change {
                app.refresh
                app.droplet_hash
              }.from(nil)
            end

            it "does not save the detected buildpack" do
              expect {
                ignore_staging_error { stage }
              }.to_not change { app.detected_buildpack }.from(nil)
            end

            it "does not save the detected start command" do
              expect {
                ignore_staging_error { stage }
              }.to_not change { app.detected_start_command }.from('')
            end

            it "does not call provided callback" do
              callback_called = false
              ignore_staging_error do
                stage { callback_called = true }
              end
              expect(callback_called).to be false
            end
          end

          context "when staging was already marked as failed" do
            before do
              @before_staging_completion = -> {
                app.mark_as_failed_to_stage
              }
            end

            it "does not mark the app as staged" do
              expect { stage rescue nil }.not_to change { app.refresh.staged? }
            end

            it "raises a StagingError" do
              expect {
                stage
              }.to raise_error(
                       Errors::ApiError,
                       /staging had already been marked as failed, this could mean that staging took too long/
                   )
            end
          end
        end

        context "when app staging fails without a reason" do
          let(:reply_json) { nil }
          let(:options) { { :invalid_json => true } }

          it "logs StagingError instead of raising to avoid stopping main runloop" do
            logger = double(:logger).as_null_object
            expect(logger).to receive(:error).with(/Encountered error on stager with id #{stager_id}/)

            allow(Steno).to receive_messages(:logger => logger)
            stage
          end

          it "keeps the app as not staged" do
            expect { stage }.to_not change { app.staged? }.from(false)
          end

          it "does not save the detected buildpack" do
            expect { stage }.to_not change { app.detected_buildpack }.from(nil)
          end

          it "does not save the detected buildpack guid" do
            expect { stage }.to_not change { app.detected_buildpack_guid }.from(nil)
          end

          it "does not save the detected start command" do
            expect { stage }.to_not change { app.detected_start_command }.from('')
          end

          it "does not call provided callback (not yet)" do
            callback_called = false
            stage { callback_called = true }
            expect(callback_called).to be false
          end

          it "marks the app as having failed to stage" do
            expect { stage }.to change { app.staging_failed? }.to(true)
          end

          it "leaves the app with a generic staging failed reason" do
            expect { stage }.to change { app.staging_failed_reason }.to("StagingError")
          end
        end

        context "when app staging returned an error response" do
          let(:reply_json_error) { "staging failed" }

          it "logs StagingError instead of raising to avoid stopping main runloop" do
            logger = double(:logger).as_null_object

            expect(logger).to receive(:error) do |msg|
              expect(msg).to match(/Encountered error on stager with id #{stager_id}/)
            end

            allow(Steno).to receive_messages(:logger => logger)
            stage
          end

          it "keeps the app as not staged" do
            expect { stage }.to_not change { app.staged? }.from(false)
          end

          it "does not save the detected buildpack" do
            expect { stage }.to_not change { app.detected_buildpack }.from(nil)
          end

          it "does not save the detected buildpack guid" do
            expect { stage }.to_not change { app.detected_buildpack_guid }.from(nil)
          end

          it "does not save the detected start command" do
            expect { stage }.to_not change { app.detected_start_command }.from('')
          end

          it "does not call provided callback (not yet)" do
            callback_called = false
            stage { callback_called = true }
            expect(callback_called).to be false
          end

          it "marks the app as having failed to stage" do
            expect { stage }.to change { app.staging_failed? }.to(true)
          end

          context "when a staging error is present" do
            let(:reply_error_info) {{ "type" => "NoAppDetectedError", "message" => "uh oh" }}

            it "sets the staging failed reason to the specified value" do
              expect { stage }.to change { app.staging_failed_reason }.to("NoAppDetectedError")
            end
          end

          context "when a staging error is not present" do
            let(:reply_error_info) { nil }

            it "sets a generic staging failed reason" do
              expect { stage }.to change { app.staging_failed_reason }.to("StagingError")
            end
          end
        end
      end

      describe "reserve app memory" do
        before do
          allow(stager_pool).to receive(:find_stager).with(app.stack.name, 1025, 4096).and_return(stager_id)
        end

        context "when app memory is less when configured minimum_staging_memory_mb" do
          before do
            config_hash[:staging][:minimum_staging_memory_mb] = 1025
          end

          it "decrement dea's available memory by minimum_staging_memory_mb" do
            expect(dea_pool).to receive(:reserve_app_memory).with(stager_id, 1025)
            staging_task.stage
          end

          it "decrement stager's available memory by minimum_staging_memory_mb" do
            expect(stager_pool).to receive(:reserve_app_memory).with(stager_id, 1025)
            staging_task.stage
          end
        end

        context "when app memory is greater when configured minimum_staging_memory_mb" do
          it "decrement dea's available memory by app memory" do
            expect(dea_pool).to receive(:reserve_app_memory).with(stager_id, 1024)
            staging_task.stage
          end

          it "decrement stager's available memory by app memory" do
            expect(stager_pool).to receive(:reserve_app_memory).with(stager_id, 1024)
            staging_task.stage
          end
        end
      end
    end

    describe ".staging_request" do
      let(:app) { AppFactory.make :droplet_hash => nil, :package_state => "PENDING" }

      before do
        3.times do
          instance = ManagedServiceInstance.make(:space => app.space)
          binding = ServiceBinding.make(:app => app, :service_instance => instance)
          app.add_service_binding(binding)
        end

        SecurityGroup.make(rules: [{"protocol" => "udp", "ports" => "8080-9090", "destination" => "198.41.191.47/1"}], staging_default: true)
        SecurityGroup.make(rules: [{"protocol" => "tcp", "ports" => "8080-9090", "destination" => "198.41.191.48/1"}], staging_default: true)
        SecurityGroup.make(rules: [{"protocol" => "tcp", "ports" => "80",        "destination" => "0.0.0.0/0"}], staging_default: false)
      end

      it "includes app guid, task id and download/upload uris" do
        allow(blobstore_url_generator).to receive(:app_package_download_url).with(app).and_return("http://www.app.uri")
        allow(blobstore_url_generator).to receive(:droplet_upload_url).with(app).and_return("http://www.droplet.upload.uri")
        allow(blobstore_url_generator).to receive(:buildpack_cache_download_url).with(app).and_return("http://www.buildpack.cache.download.uri")
        allow(blobstore_url_generator).to receive(:buildpack_cache_upload_url).with(app).and_return("http://www.buildpack.cache.upload.uri")
        request = staging_task.staging_request

        expect(request[:app_id]).to eq(app.guid)
        expect(request[:task_id]).to eq(staging_task.task_id)
        expect(request[:download_uri]).to eq("http://www.app.uri")
        expect(request[:upload_uri]).to eq("http://www.droplet.upload.uri")
        expect(request[:buildpack_cache_upload_uri]).to eq("http://www.buildpack.cache.upload.uri")
        expect(request[:buildpack_cache_download_uri]).to eq("http://www.buildpack.cache.download.uri")
      end

      it "includes misc app properties" do
        request = staging_task.staging_request
        expect(request[:properties][:meta]).to be_kind_of(Hash)
      end

      it "includes service binding properties" do
        request = staging_task.staging_request
        expect(request[:properties][:services].count).to eq(3)
        request[:properties][:services].each do |service|
          expect(service[:credentials]).to be_kind_of(Hash)
          expect(service[:options]).to be_kind_of(Hash)
        end
      end

      context "when app does not have buildpack" do
        it "returns nil for buildpack" do
          app.buildpack = nil
          request = staging_task.staging_request
          expect(request[:properties][:buildpack]).to be_nil
        end
      end

      context "when app has a buildpack" do
        it "returns url for buildpack" do
          app.buildpack = "git://example.com/foo.git"
          request = staging_task.staging_request
          expect(request[:properties][:buildpack]).to eq("git://example.com/foo.git")
          expect(request[:properties][:buildpack_git_url]).to eq("git://example.com/foo.git")
        end

        it "doesn't return a buildpack key" do
          app.buildpack = "git://example.com/foo.git"
          request = staging_task.staging_request
          expect(request[:properties]).to_not have_key(:buildpack_key)
        end
      end

      it "includes start app message" do
        request = staging_task.staging_request
        expect(request[:start_message]).to be_a(Dea::StartAppMessage)
      end

      it "includes app index 0" do
        request = staging_task.staging_request
        expect(request[:start_message]).to include ({ :index => 0 })
      end

      it "overwrites droplet sha" do
        request = staging_task.staging_request
        expect(request[:start_message]).to include ({ :sha1 => nil })
      end

      it "overwrites droplet download uri" do
        request = staging_task.staging_request
        expect(request[:start_message]).to include ({ :executableUri => nil })
      end

      describe "the list of admin buildpacks" do
        let!(:buildpack_a) { Buildpack.make(key: "a key", position: 2) }
        let!(:buildpack_b) { Buildpack.make(key: "b key", position: 1) }
        let!(:buildpack_c) { Buildpack.make(key: "c key", position: 4) }

        let(:buildpack_file_1) { Tempfile.new("admin buildpack 1") }
        let(:buildpack_file_2) { Tempfile.new("admin buildpack 2") }
        let(:buildpack_file_3) { Tempfile.new("admin buildpack 3") }

        let(:buildpack_blobstore) { CloudController::DependencyLocator.instance.buildpack_blobstore }

        before do
          buildpack_blobstore.cp_to_blobstore(buildpack_file_1.path, "a key")
          buildpack_blobstore.cp_to_blobstore(buildpack_file_2.path, "b key")
          buildpack_blobstore.cp_to_blobstore(buildpack_file_3.path, "c key")
        end

        context "when a specific buildpack is not requested" do
          it "includes a list of admin buildpacks as hashes containing its blobstore URI and key" do
            Timecop.freeze do #download_uri have an expire_at
              request = staging_task.staging_request

              admin_buildpacks = request[:admin_buildpacks]

              expect(admin_buildpacks).to have(3).items
              expect(admin_buildpacks).to include(url: buildpack_blobstore.download_uri("a key"), key: "a key")
              expect(admin_buildpacks).to include(url: buildpack_blobstore.download_uri("b key"), key: "b key")
              expect(admin_buildpacks).to include(url: buildpack_blobstore.download_uri("c key"), key: "c key")
            end
          end
        end

        context "when a specific buildpack is requested" do
          before do
            app.buildpack = Buildpack.first.name
            app.save()
          end

          it "includes a list of admin buildpacks so that the system doesn't think the buildpacks are gone" do
            request = staging_task.staging_request

            admin_buildpacks = request[:admin_buildpacks]

            expect(admin_buildpacks).to have(3).items
          end
        end

        context "when a buildpack is disabled" do
          before do
            buildpack_a.enabled = false
            buildpack_a.save
          end

          context "when a specific buildpack is not requested" do
            it "includes a list of enabled admin buildpacks as hashes containing its blobstore URI and key" do
              Timecop.freeze do #download_uri have an expire_at
                request = staging_task.staging_request

                admin_buildpacks = request[:admin_buildpacks]

                expect(admin_buildpacks).to have(2).items
                expect(admin_buildpacks).to include(url: buildpack_blobstore.download_uri("b key"), key: "b key")
                expect(admin_buildpacks).to include(url: buildpack_blobstore.download_uri("c key"), key: "c key")
              end
            end
          end

          context "when a buildpack has missing bits" do
            it "does not include the buildpack" do
              buildpack_d = Buildpack.make(key: "d key", position: 5)

              request = staging_task.staging_request
              admin_buildpacks = request[:admin_buildpacks]
              expect(admin_buildpacks).to have(2).items
              expect(admin_buildpacks).to_not include(key: "d key", url: nil)
            end
          end
        end

      end

      it "includes the key of an admin buildpack when the app has a buildpack specified" do
        buildpack = Buildpack.make()
        app.buildpack = buildpack.name
        app.save()

        request = staging_task.staging_request
        expect(request[:properties][:buildpack_key]).to eql buildpack.key
      end

      it "doesn't include the custom buildpack url keys when the app has a buildpack specified" do
        buildpack = Buildpack.make()
        app.buildpack = buildpack.name
        app.save()

        request = staging_task.staging_request
        expect(request[:properties]).to_not have_key(:buildpack)
        expect(request[:properties]).to_not have_key(:buildpack_git_url)
      end

      it "includes egress security group staging information by aggregating all sg with staging_default=true" do
        request = staging_task.staging_request
        expect(request[:egress_network_rules]).to match_array([
          {"protocol"=>"udp","ports"=>"8080-9090","destination"=>"198.41.191.47/1"},
          {"protocol"=>"tcp","ports"=>"8080-9090","destination"=>"198.41.191.48/1"}
        ])
      end

      describe "evironment variables" do
        before do
          app.environment_json   = { 'KEY' => 'value' }
        end

        it "includes app environment variables" do
          request = staging_task.staging_request
          expect(request[:properties][:environment]).to eq(['KEY=value'])
        end

        it "includes environment variables from staging environment variable group" do
          group = EnvironmentVariableGroup.staging
          group.environment_json = { 'STAGINGKEY' => 'staging_value' }
          group.save

          request = staging_task.staging_request
          expect(request[:properties][:environment]).to match_array(['KEY=value', 'STAGINGKEY=staging_value'])
        end

        it "prefers app environment variables when they conflict with staging group variables" do
          group = EnvironmentVariableGroup.staging
          group.environment_json = { 'KEY' => 'staging_value' }
          group.save

          request = staging_task.staging_request
          expect(request[:properties][:environment]).to match_array(['KEY=value'])
        end
      end
    end
  end
end

def stub_schedule_sync(&before_resolve)
  allow(EM).to receive(:schedule_sync) do |&blk|
    promise = VCAP::Concurrency::Promise.new

    begin
      if blk.arity > 0
        blk.call(promise)
      else
        promise.deliver(blk.call)
      end
    rescue Exception => e
      promise.fail(e)
    end

    # Call before_resolve block before trying to resolve the promise
    before_resolve.call

    promise.resolve
  end
end

def ignore_staging_error
  yield
rescue VCAP::Errors::ApiError => e
  raise e unless e.name == "StagingError"
end
