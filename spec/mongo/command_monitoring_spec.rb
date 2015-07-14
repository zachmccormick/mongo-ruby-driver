require 'spec_helper'

describe 'Command Monitoring' do

  COMMAND_MONITORING_TESTS.each do |file|

    spec = Mongo::CommandMonitoring::Spec.new(file)

    let(:collection_name) do
      spec.collection_name
    end

    let(:database_name) do
      spec.database_name
    end

    after do
      authorized_client[collection_name].find.delete_many
    end

    class CommandMonitoringTestSubscriber

      def started(event)
      end

      def succeeded(event)
      end

      def failed(event)
      end
    end

    let(:subscriber) do
      CommandMonitoringTestSubscriber.new
    end

    let(:monitoring) do
      authorized_client.instance_variable_get(:@monitoring)
    end

    spec.tests.each do |test|

      context(test.description) do

        before do
          # Force auth to run when running single test before we subscribe.
          authorized_collection.find.to_a
          authorized_client.subscribe(Mongo::Monitoring::COMMAND, subscriber)
        end

        after do
          monitoring.subscribers[Mongo::Monitoring::COMMAND].delete(subscriber)
        end

        it "generates the appropriate events" do
          test.expectations.each do |expectation|
            expect(subscriber).to receive(expectation.monitoring_call) do |event|
              expect(event.command_name).to eq(expectation.command_name)
              expect(event.database_name).to eq(expectation.database_name)
            end
          end
          begin
            test.operation.execute(authorized_client[collection_name])
          rescue Exception => e
            p e
          end
        end
      end
    end
  end
end
