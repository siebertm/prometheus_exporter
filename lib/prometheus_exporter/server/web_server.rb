# frozen_string_literal: true

require 'rack'
require 'timeout'
require 'zlib'
require 'stringio'

module PrometheusExporter::Server
  class WebServer
    attr_reader :collector

    def initialize(collector: nil, timeout: PrometheusExporter::DEFAULT_TIMEOUT)
      @metrics_total = PrometheusExporter::Metric::Counter.new("collector_metrics_total", "Total metrics processed by exporter web.")

      @sessions_total = PrometheusExporter::Metric::Counter.new("collector_sessions_total", "Total send_metric sessions processed by exporter web.")

      @bad_metrics_total = PrometheusExporter::Metric::Counter.new("collector_bad_metrics_total", "Total mis-handled metrics by collector.")

      @metrics_total.observe(0)
      @sessions_total.observe(0)
      @bad_metrics_total.observe(0)

      @collector = collector || Collector.new
      @port = port
      @timeout = timeout
    end

    def call(env)
      req = Rack::Request.new(env)
      res = Rack::Response.new([], 200, 'Content-Type' => 'text/plain; charset=utf-8')

      if req.path == '/metrics'
        if req.header["accept-encoding"].to_s.include?("gzip")
          sio = StringIO.new
          collected_metrics = metrics
          begin
            writer = Zlib::GzipWriter.new(sio)
            writer.write(collected_metrics)
          ensure
            writer.close
          end
          res.body = [sio.string]
          res["content-encoding"] = "gzip"
        else
          res.body = [metrics]
        end
      elsif req.path == '/send-metrics'
        handle_metrics(req, res)
      else
        res.status = 404
        res.body = ["Not Found! The Prometheus Ruby Exporter only listens on /metrics and /send-metrics"]
      end
    end

    def handle_metrics(req, res)
      @sessions_total.observe
      req.body do |block|
        begin
          @metrics_total.observe
          @collector.process(block)
        rescue => e
          if @verbose
            STDERR.puts
            STDERR.puts e.inspect
            STDERR.puts e.backtrace
            STDERR.puts
          end
          @bad_metrics_total.observe
          res.body = "Bad Metrics #{e}"
          res.status = e.respond_to?(:status_code) ? e.status_code : 500
          return
        end
      end

      res.body = ["OK"]
      res.status = 200
    end

    def metrics
      metric_text = nil
      begin
        Timeout::timeout(@timeout) do
          metric_text = @collector.prometheus_metrics_text
        end
      rescue Timeout::Error
        # we timed out ... bummer
        STDERR.puts "Generating Prometheus metrics text timed out"
      end

      metrics = []

      metrics << add_gauge(
        "collector_working",
        "Is the master process collector able to collect metrics",
        metric_text && metric_text.length > 0 ? 1 : 0
      )

      metrics << add_gauge(
        "collector_rss",
        "total memory used by collector process",
        get_rss
      )

      metrics << @metrics_total
      metrics << @sessions_total
      metrics << @bad_metrics_total

      <<~TEXT
      #{metrics.map(&:to_prometheus_text).join("\n\n")}
      #{metric_text}
      TEXT
    end

    def get_rss
      @pagesize ||= `getconf PAGESIZE`.to_i rescue 4096
      @pid ||= Process.pid
      File.read("/proc/#{@pid}/statm").split(' ')[1].to_i * @pagesize rescue 0
    end

    def add_gauge(name, help, value)
      gauge = PrometheusExporter::Metric::Gauge.new(name, help)
      gauge.observe(value)
      gauge
    end
  end
end
