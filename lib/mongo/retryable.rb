# Copyright (C) 2015 MongoDB, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

module Mongo

  # Defines basic behaviour around retrying operations.
  #
  # @since 2.1.0
  module Retryable

    # The not master error message.
    #
    # @since 2.1.0
    NOT_MASTER = 'not master'.freeze
    RUNNER_DEAD = 'RUNNER_DEAD'.freeze

    # Execute a read operation with a retry.
    #
    # @api private
    #
    # @example Execute the read.
    #   read_with_retry do
    #     ...
    #   end
    #
    # @note This only retries read operations on socket errors.
    #
    # @param [ Integer ] attempt The retry attempt count - for internal use.
    # @param [ Proc ] block The block to execute.
    #
    # @return [ Result ] The result of the operation.
    #
    # @since 2.1.0
    def read_with_retry(attempt = 0, &block)
      begin
        block.call
      rescue Error::SocketError, Error::SocketTimeoutError, Error::OperationFailure => e
        connection_error = e.kind_of?(Error::SocketError) || e.kind_of?(Error::SocketTimeoutError)
        operation_failure = e.kind_of?(Error::OperationFailure)
        if connection_error
          rescan!
        end
        Mongo::Logger.logger.warn("[jontest] got error for read on #{cluster.servers.inspect}: #{e.inspect}, attempt #{attempt}")
        if connection_error || (operation_failure && cluster.sharded? && (e.retryable? || e.unauthorized?))
          if attempt < cluster.max_read_retries
            if operation_failure && e.unauthorized?
              Mongo::Logger.logger.warn("[jontest] got unauthorized for read on #{cluster.servers.inspect}, re-authenticating")
              cluster.servers.each {|server| server.context.with_connection {|conn| conn.authenticate! } }
            end

            # We don't scan the cluster in this case as Mongos always returns
            # ready after a ping no matter what the state behind it is.
            sleep(cluster.read_retry_interval)
            read_with_retry(attempt + 1, &block)
          else
            raise e
          end
        else
          raise e
        end
      end
    end

    # Execute a write operation with a retry.
    #
    # @api private
    #
    # @example Execute the write.
    #   write_with_retry do
    #     ...
    #   end
    #
    # @note This only retries operations on not master failures, since it is
    #   the only case we can be sure a partial write did not already occur.
    #
    # @param [ Proc ] block The block to execute.
    #
    # @return [ Result ] The result of the operation.
    #
    # @since 2.1.0
    def write_with_retry(&block)
      write_with_retry_helper(0, &block)
    end

    private
    def rescan!
      cluster.scan!
      # Do a disconnect to force a reconnection to the cluster if we have connection problems
      cluster.disconnect!
    end

    def write_with_retry_helper(attempt, &block)
      begin
        block.call
      rescue Error::SocketError, Error::SocketTimeoutError, Error::OperationFailure => e
        connection_error = e.kind_of?(Error::SocketError) || e.kind_of?(Error::SocketTimeoutError)
        operation_failure = e.kind_of?(Error::OperationFailure)
        runner_dead = e.message.include?(RUNNER_DEAD)
        not_master = e.message.include?(NOT_MASTER)
        if connection_error || runner_dead || not_master
          if connection_error
            Mongo::Logger.logger.warn("[jontest] got connection error in write on #{cluster.servers.inspect}, attempt #{attempt}")
          elsif runner_dead
            Mongo::Logger.logger.warn("[jontest] got RUNNER_DEAD in write on #{cluster.servers.inspect}, attempt #{attempt}")
          elsif not_master
            Mongo::Logger.logger.warn("[jontest] got not master in write on #{cluster.servers.inspect}, attempt #{attempt}")
          end
          rescan!
        end
        if connection_error || (operation_failure && (e.retryable? || e.unauthorized?)) || runner_dead
          # We're using max_read_retries here but if we got one of the errors that is causing us to be here, we should be retrying
          # often anyway
          if attempt < cluster.max_read_retries
            if operation_failure && e.unauthorized?
              Mongo::Logger.logger.warn("[jontest] got unauthorized for write on #{cluster.servers.inspect}, re-authenticating")
              cluster.servers.each {|server| server.context.with_connection {|conn| conn.authenticate! } }
            end

            # We don't scan the cluster in this case as Mongos always returns
            # ready after a ping no matter what the state behind it is.
            sleep(cluster.read_retry_interval)
            write_with_retry_helper(attempt + 1, &block)
          else
            raise e
          end
        else
          raise e
        end
      end
    end
  end
end
