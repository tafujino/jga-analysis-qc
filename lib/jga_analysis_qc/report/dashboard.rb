# frozen_string_literal: true

require 'active_support'
require 'active_support/core_ext/hash/indifferent_access'
require 'pathname'
require 'fileutils'
require 'open3'
require 'thor'

require_relative '../settings'
require_relative '../chr_region'
require_relative 'render'
require_relative '../sample'
require_relative 'c3js'

module JgaAnalysisQC
  module Report
    class Dashboard
      include Thor::Shell

      TEMPLATE_PREFIX = 'dashboard'
      COVERAGE_STATS_TYPES = { mean: 'mean' }.freeze
      X_AXIS_LABEL_HEIGHT = 100

      # @param result_dir [Pathname]
      # @param samples    [Array<Sample>]
      def initialize(result_dir, samples)
        @result_dir = result_dir
        @samples = samples
        @sample_col = C3js::Column.new(:sample_name, 'sample name')
        @default_chart_params = {
          x: @sample_col,
          x_axis_label_height: X_AXIS_LABEL_HEIGHT
        }
      end

      # @return [Pathname] HTML path
      def render
        [D3_JS_PATH, C3_JS_PATH, C3_CSS_PATH].each do |src_path|
          Render.copy_file(src_path, @result_dir)
        end
        table_path = @result_dir / MEAN_COVERAGE_TABLE_FILENAME
        create_mean_coverage_table(table_path)
        autosome_mean_coverage_plot_path =
          plot_autosome_mean_coverage(@result_dir, table_path)
        chrXY_normalized_mean_coverage_plot_path =
          plot_chrXY_normalized_mean_coverage(@result_dir, table_path)
        Render.run(
          TEMPLATE_PREFIX,
          @result_dir,
          binding,
          toc_nesting_level: DASHBOARD_TOC_NESTING_LEVEL
        )
      end

      private

      # @return [C3js::Data]
      def ts_tv_ratio
        @samples.flat_map do |sample|
          sample.vcf_collection.vcfs.map do |vcf|
            {
              sample_name: sample.name,
              chr_region: vcf.chr_region,
              ts_tv_ratio: vcf.bcftools_stats&.ts_tv_ratio
            }
          end
        end.compact.then { |a| C3js::Data.new(a) }
      end

      # @return [Hash{ ChrRegion => String }]
      def ts_tv_ratio_html
        tstv_col = C3js::Column.new(:ts_tv_ratio, 'ts/tv')
        ts_tv_ratio.then do |data|
          HAPLOTYPECALLER_REGIONS.map.to_h do |chr_region|
            html = data.select(chr_region: chr_region)
                     .bar_chart_html(
                       @sample_col,
                       tstv_col,
                       bindto: "tstv_#{chr_region.id}",
                       **@default_chart_params
                     )
            [chr_region, html]
          end
        end
      end

      # @return [C3js::Data]
      def coverage_stats
        @samples.flat_map do |sample|
          sample
            .cram
            &.picard_collect_wgs_metrics_collection
            &.picard_collect_wgs_metrics&.map do |e|
            h = COVERAGE_STATS_TYPES.keys.map.to_h do |type|
              [type, e.coverage_stats.send(type)]
            end
            h.merge(sample_name: sample.name,
                    chr_region: e.chr_region)
          end
        end.compact.then { |a| C3js::Data.new(a) }
      end

      # @return [Hash{ ChrRegion => Hash{ Symbol => String } }]
      def coverage_stats_html
        coverage_stats_cols = COVERAGE_STATS_TYPES.map do |id, label|
          C3js::Column.new(id, label)
        end
        coverage_stats.then do |data|
          WGS_METRICS_REGIONS.map.to_h do |chr_region|
            coverage_stats_cols.map.to_h do |col|
              bindto = "coverage_stats_#{chr_region.id}_#{col.id}"
              html = data.select(chr_region: chr_region)
                         .bar_chart_html(
                           @sample_col,
                           col,
                           bindto: bindto,
                           **@default_chart_params
                         )
              [col, html]
            end.then do |htmls_of_chr_region|
              [chr_region, htmls_of_chr_region]
            end
          end
        end
      end

      # @param table_path [Pathname]
      def create_mean_coverage_table(table_path)
        CSV.open(table_path, 'w', col_sep: "\t") do |tsv|
          tsv << [
            'sample_id',
            AUTOSOME_MEAN_COVERAGE_KEY,
            CHR_X_NORMALIZED_MEAN_COVERAGE_KEY,
            CHR_Y_NORMALIZED_MEAN_COVERAGE_KEY
          ]
          @samples.each do |sample|
            mean_coverage = sample
                              &.cram
                              &.picard_collect_wgs_metrics_collection
                              &.picard_collect_wgs_metrics
                              &.map&.to_h do |wgs_metrics|
              [wgs_metrics.chr_region.id, wgs_metrics.coverage_stats.mean]
            end
            if mean_coverage
              autosome_mean_coverage = mean_coverage[WGS_METRICS_AUTOSOME_REGION.id]
              if autosome_mean_coverage
                chr_x_normalized_mean_coverage, chr_y_normalized_mean_coverage =
                  [WGS_METRICS_CHR_X_REGION, WGS_METRICS_CHR_Y_REGION].map do |region|
                  next nil unless mean_coverage[region.id]

                  mean_coverage[region.id] / autosome_mean_coverage
                end
              end
            end
            tsv << [
              sample.name,
              fill_NA_if_nil(autosome_mean_coverage),
              fill_NA_if_nil(chr_x_normalized_mean_coverage),
              fill_NA_if_nil(chr_y_normalized_mean_coverage)
            ]
          end
        end
        say_status 'create', table_path, :green
      end

      # @param value [Float]
      # @return      [Float, String]
      def fill_NA_if_nil(value)
        value.nil? ? 'NA' : value
      end

      # @param result_dir [Pathname]
      # @param table_path [Pathname]
      # @return           [Pathname]
      def plot_autosome_mean_coverage(result_dir, table_path)
        plot_path = result_dir / 'autosome_mean_coverage.hist.png'
        r_script = <<~R_SCRIPT
          library(ggplot2)
          library(readr)

          d <- as.data.frame(read_tsv("#{table_path}"))
          g <- ggplot(d, aes(x = #{AUTOSOME_MEAN_COVERAGE_KEY}))
          g <- g + geom_histogram(position="identity", alpha=0.8, color="darkgreen")
          g <- g + theme_classic()
          g <- g + theme(text=element_text(size=20))
          g <- g + xlab("#{WGS_METRICS_AUTOSOME_REGION.id} mean coverage")
          g <- g + ylab("Number of subjects")
          ggsave(file="#{plot_path}", plot=g, height=5, width=8)
        R_SCRIPT
        r_submit(r_script, plot_path.sub_ext('.log'))
        plot_path
      end

      # @param result_dir [Pathname]
      # @param table_path [Pathname]
      # @return           [Pathname]
      def plot_chrXY_normalized_mean_coverage(result_dir, table_path)
        plot_path = result_dir / 'chrXY_normalized_mean_coverage.scatter.png'
        r_script = <<~R_SCRIPT
          library(ggplot2)
          library(readr)

          d <- as.data.frame(read_tsv("#{table_path}"))
          g <- ggplot(d, aes(x = #{CHR_X_NORMALIZED_MEAN_COVERAGE_KEY}, y = #{CHR_Y_NORMALIZED_MEAN_COVERAGE_KEY}))
          g <- g + geom_point(size = 2, color="darkgreen")
          g <- g + theme_classic()
          g <- g + theme(text=element_text(size=20))
          g <- g + xlab("#{WGS_METRICS_CHR_X_REGION.id} normalized mean coverage")
          g <- g + ylab("#{WGS_METRICS_CHR_Y_REGION.id} normalized mean coverage")
          ggsave(file="#{plot_path}", plot=g, height=8, width=8)
        R_SCRIPT
        r_submit(r_script, plot_path.sub_ext('.log'))
        plot_path
      end

      # @param cmd      [String]
      # @param log_path [Pathname]
      def r_submit(cmd, log_path)
        File.open(log_path, 'w') do |f|
          Open3.popen3('R --slave --vanilla') do |i, o, e|
            i.puts cmd if cmd
            i.close
            o.each { |line| f.puts line }
            e.each { |line| f.puts line }
          end
        end
      end
    end
  end
end
