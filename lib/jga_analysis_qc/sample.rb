# frozen_string_literal: true

require 'fileutils'
require 'pathname'

require_relative 'settings'
require_relative 'sample/vcf_collection'
require_relative 'sample/cram'
require_relative 'report/render'

module JgaAnalysisQC
  class Sample
    TEMPLATE_PREFIX = 'report'

    # @return [String] sample name
    attr_reader :name

    # @return [dir]
    attr_reader :dir

    # @return [VcfCollection]
    attr_reader :vcf_collection

    # @return [Cram, nil]
    attr_reader :cram

    # @param name           [String]
    # @param dir            [Pathname]
    # @param vcf_collection [VcfCollection]
    # @param cram           [Cram, nil]
    def initialize(name, dir, vcf_collection, cram = nil)
      @name = name
      @dir = dir
      @vcf_collection = vcf_collection
      @cram = cram
    end

    # @param show_path [Boolean]
    def render(show_path: true)
      Report::Render.run(
        TEMPLATE_PREFIX,
        @dir,
        binding,
        toc_nesting_level: Report::SAMPLE_TOC_NESTING_LEVEL
      )
    end

    class << self
      # @param result_dir  [Pathname]
      # @param sample_name [String]
      # @return            [Sample]
      def parse(result_dir, sample_name)
        sample_dir = result_dir / sample_name
        vcf_collection = read_vcf_collection(sample_dir, sample_name)
        cram = read_cram(sample_dir, sample_name)
        Sample.new(sample_name, sample_dir, vcf_collection, cram)
      end

      private

      # @param sample_dir  [Pathname]
      # @param sample_name [String]
      # @return            [VcfCollection]
      def read_vcf_collection(sample_dir, sample_name)
        vcfs = HAPLOTYPECALLER_REGIONS.filter_map do |chr_region|
          vcf_basename = "#{sample_name}.#{chr_region.id}.g.vcf.gz"
          vcf_path = sample_dir / vcf_basename
          next unless vcf_path.exist?

          bcftools_stats_path = sample_dir / "#{vcf_basename}.bcftools-stats"
          bcftools_stats = Vcf::BcftoolsStats.parse(chr_region, bcftools_stats_path)
          Vcf.new(vcf_path, chr_region, bcftools_stats)
        end
        VcfCollection.new(vcfs)
      end

      # @param sample_dir  [Pathname]
      # @param sample_name [String]
      # @return            [Cram, nil]
      def read_cram(sample_dir, sample_name)
        cram_basename = "#{sample_name}.cram"
        cram_path = sample_dir / cram_basename
        return nil unless cram_path.exist?

        Cram.new(
          cram_path,
          Cram::SamtoolsIdxstats.parse(sample_dir / "#{cram_basename}.idxstats"),
          Cram::SamtoolsFlagstat.parse(sample_dir / "#{cram_basename}.flagstat"),
          read_picard_collect_wgs_metrics_collection(sample_dir, cram_basename),
          read_picard_collect_base_distribution_per_cycle(sample_dir, cram_basename)
        )
      end

      # @param sample_dir    [Pathname]
      # @param cram_basename [String]
      # @return              [Cram::PicardCollectWgsMetricsCollection]
      def read_picard_collect_wgs_metrics_collection(sample_dir, cram_basename)
        picard_collect_wgs_metrics = WGS_METRICS_REGIONS.filter_map do |chr_region|
          picard_collect_wgs_metrics_path =
            sample_dir / "#{cram_basename}.#{chr_region.id}.wgs_metrics"
          Cram::PicardCollectWgsMetrics.parse(picard_collect_wgs_metrics_path, chr_region)
        end
        Cram::PicardCollectWgsMetricsCollection.new(picard_collect_wgs_metrics)
      end

      # @param sample_dir    [Pathname]
      # @param cram_basename [String]
      # @return              [Cram::PicardCollectBaseDistributionByCycle, nil]
      def read_picard_collect_base_distribution_per_cycle(sample_dir, cram_basename)
        chart_png_path =
          sample_dir / "#{cram_basename}.collect_base_dist_by_cycle.chart.png"
        return nil unless chart_png_path.exist?

        Cram::PicardCollectBaseDistributionByCycle.new(chart_png_path)
      end
    end
  end
end
