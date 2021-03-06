module ActivePublisher
  module Async
    class InMemoryAdapter
      include ::ActivePublisher::Logging

      attr_reader :async_queue

      def initialize(drop_messages_when_queue_full = false, max_queue_size = 1_000_000, supervisor_interval = 0.2)
        logger.info "Starting in-memory publisher adapter"

        @async_queue = ::ActivePublisher::Async::InMemoryAdapter::AsyncQueue.new(
          drop_messages_when_queue_full,
          max_queue_size,
          supervisor_interval
        )
      end

      def publish(route, payload, exchange_name, options = {})
        message = ::ActivePublisher::Async::InMemoryAdapter::Message.new(route, payload, exchange_name, options)
        async_queue.push(message)
        nil
      end

      def shutdown!
        max_wait_time = ::ActivePublisher.configuration.seconds_to_wait_for_graceful_shutdown
        started_shutting_down_at = ::Time.now

        logger.info "Draining async publisher in-memory adapter queue before shutdown. current queue size: #{async_queue.size}."
        while async_queue.size > 0
          if (::Time.now - started_shutting_down_at) > max_wait_time
            logger.info "Forcing async publisher adapter shutdown because graceful shutdown period of #{max_wait_time} seconds was exceeded. Current queue size: #{async_queue.size}."
            break
          end

          sleep 0.1
        end
      end

      class AsyncQueue
        include ::ActivePublisher::Logging

        attr_accessor :drop_messages_when_queue_full,
                      :max_queue_size,
                      :supervisor_interval

        attr_reader :consumer, :queue, :supervisor

        if ::RUBY_PLATFORM == "java"
          NETWORK_ERRORS = [::MarchHare::Exception, ::Java::ComRabbitmqClient::AlreadyClosedException, ::Java::JavaIo::IOException].freeze
        else
          NETWORK_ERRORS = [::Bunny::Exception, ::Timeout::Error, ::IOError].freeze
        end

        def initialize(drop_messages_when_queue_full, max_queue_size, supervisor_interval)
          @drop_messages_when_queue_full = drop_messages_when_queue_full
          @max_queue_size = max_queue_size
          @supervisor_interval = supervisor_interval
          @queue = ::Queue.new
          create_and_supervise_consumer!
        end

        def push(message)
          # default of 1_000_000 messages
          if queue.size > max_queue_size
            # Drop messages if the queue is full and we were configured to do so
            return if drop_messages_when_queue_full

            # By default we will raise an error to push the responsibility onto the caller
            fail ::ActivePublisher::Async::InMemoryAdapter::UnableToPersistMessageError, "Queue is full, messages will be dropped."
          end

          queue.push(message)
        end

        def size
          queue.size
        end

      private

        def await_network_reconnect
          sleep ::ActivePublisher::RabbitConnection::NETWORK_RECOVERY_INTERVAL
        end

        def create_and_supervise_consumer!
          @consumer = create_consumer
          @supervisor = ::Thread.new do
            loop do
              unless consumer.alive?
                # We might need to requeue the last message.
                queue.push(@current_message) unless @current_message.nil?
                consumer.kill
                @consumer = create_consumer
              end

              # Pause before checking the consumer again.
              sleep supervisor_interval
            end
          end
        end

        def create_consumer
          ::Thread.new do
            loop do
              # Write "current_message" so we can requeue should something happen to the consumer.
              @current_message = message = queue.pop

              begin
                ::ActivePublisher.publish(message.route, message.payload, message.exchange_name, message.options)

                # Reset
                @current_message = nil
              rescue *NETWORK_ERRORS
                # Sleep because connection is down
                await_network_reconnect

                # Requeue and try again.
                queue.push(message)
              rescue => unknown_error
                # Do not requeue the message because something else horrible happened.
                @current_message = nil

                ::ActivePublisher.configuration.error_handler.call(unknown_error, {:route => message.route, :payload => message.payload, :exchange_name => message.exchange_name, :options => message.options})

                # TODO: Find a way to bubble this out of the thread for logging purposes.
                # Reraise the error out of the publisher loop. The Supervisor will restart the consumer.
                raise unknown_error
              end
            end
          end
        end
      end

      class Message
        attr_reader :route, :payload, :exchange_name, :options

        def initialize(route, payload, exchange_name, options)
          @route = route
          @payload = payload
          @exchange_name = exchange_name
          @options = options
        end
      end

      class UnableToPersistMessageError < ::StandardError
      end
    end
  end
end
