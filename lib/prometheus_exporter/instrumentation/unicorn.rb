begin
  require 'raindrops'
rescue LoadError
  # No raindrops available, dont do anything
end

module PrometheusExporter::Instrumentation
  # collects stats from unicorn
  class Unicorn
    def self.start(worker_processes:, socket:, client: nil, frequency: 30)
      unicorn_collector = new(worker_processes: worker_processes, socket: socket)
      client ||= PrometheusExporter::Client.default
      Thread.new do
        loop do
          metric = unicorn_collector.collect
          client.send_json metric
        rescue Error => e
          STDERR.puts("Prometheus Exporter Failed To Collect Unicorn Stats #{e}")
        ensure
          sleep frequency
        end
      end
    end

    def initialize(worker_processes:, socket:)
      @worker_processes = worker_processes
      @socket = socket
      @tcp = socket =~ /\A.+:\d+\z/
    end

    def collect
      metric = {}
      metric[:type] = 'unicorn'
      collect_unicorn_stats(metric)
      metric
    end

    def collect_unicorn_stats(metric)
      stats = socket_stats

      metric[:active_workers_total] = stats.active
      metric[:request_backlog_total] = stats.queued
      metric[:workers_total] = @worker_processes
    end

    private

    def socket_stats
      if @tcp
        Raindrops::Linux.tcp_listener_stats(@socket)[@socket]
      else
        Raindrops::Linux.unix_listener_stats(@socket)[@socket]
      end
    end
  end
end
