require "rails_helper"

RSpec.describe ClusteringService do
  let(:user)      { create(:user) }
  let(:dashboard) { create(:dashboard, :ready, user: user) }
  let(:top_genes) { %w[GENE1 GENE2 GENE3] }

  let(:analysis) do
    create(:analysis, :clustering, :running,
           dashboard: dashboard,
           params: { "n_clusters" => 2, "n_top_genes" => 3 })
  end

  def seed_feature_importance(genes = top_genes)
    create(:analysis, :feature_importance_ready,
           dashboard: dashboard,
           result: { "top_genes" => genes.map { |g| { "gene" => g } } })
  end

  def seed_expression(case_id, gene, tpm)
    create(:gene_expression,
           dashboard: dashboard,
           case_id:   case_id,
           gene_name: gene,
           gene_id:   gene,
           tpm:       tpm,
           project_id: "TCGA-BRCA")
  end

  describe "#call" do
    context "when no Feature Importance analysis exists" do
      it "raises a clear error" do
        expect { described_class.new(analysis).call }
          .to raise_error(/Feature Importance/)
      end
    end

    context "when Feature Importance has empty top_genes" do
      it "still raises asking to run Feature Importance" do
        create(:analysis, :feature_importance_ready,
               dashboard: dashboard,
               result: { "top_genes" => [] })

        expect { described_class.new(analysis).call }
          .to raise_error(/Feature Importance/)
      end
    end

    context "when there are too few cases for the requested k" do
      before do
        seed_feature_importance
        # n_clusters * 2 = 4 minimum required, only 3 cases provided
        3.times do |i|
          c = create(:patient_case, dashboard: dashboard, case_id: "C#{i}")
          seed_expression(c.case_id, "GENE1", 1.0 + i)
        end
      end

      it "raises explaining the minimum cohort size" do
        expect { described_class.new(analysis).call }
          .to raise_error(/минимум/)
      end
    end

    context "when there is no expression data at all" do
      before do
        seed_feature_importance
        4.times { |i| create(:patient_case, dashboard: dashboard, case_id: "C#{i}") }
      end

      it "raises explaining the missing expression data" do
        expect { described_class.new(analysis).call }
          .to raise_error(/экспрессии/)
      end
    end

    context "with two well-separated synthetic groups" do
      let(:n_per_group) { 5 }

      before do
        seed_feature_importance

        n_per_group.times do |i|
          c = create(:patient_case,
                     dashboard: dashboard,
                     case_id: "A#{i}",
                     vital_status: "Alive",
                     age_at_index: 50,
                     days_to_last_follow_up: 800.0,
                     days_to_death: nil)
          seed_expression(c.case_id, "GENE1", 100.0)
          seed_expression(c.case_id, "GENE2", 0.5)
          seed_expression(c.case_id, "GENE3", 0.5)
        end

        n_per_group.times do |i|
          c = create(:patient_case,
                     dashboard: dashboard,
                     case_id: "B#{i}",
                     vital_status: "Dead",
                     age_at_index: 70,
                     days_to_death: 300.0,
                     days_to_last_follow_up: nil)
          seed_expression(c.case_id, "GENE1", 0.5)
          seed_expression(c.case_id, "GENE2", 100.0)
          seed_expression(c.case_id, "GENE3", 100.0)
        end
      end

      it "returns the expected top-level structure" do
        result = described_class.new(analysis).call

        expect(result).to include(
          "algorithm"   => "clustering",
          "n_clusters"  => 2,
          "n_cases"     => 2 * n_per_group,
          "n_top_genes" => 3
        )
        expect(result["top_genes_used"]).to eq(top_genes)
      end

      it "labels every patient and preserves case_ids" do
        result = described_class.new(analysis).call
        expected_ids = (0...n_per_group).flat_map { |i| [ "A#{i}", "B#{i}" ] }

        expect(result["patient_clusters"].size).to eq(2 * n_per_group)
        expect(result["patient_clusters"].map { |p| p["case_id"] })
          .to match_array(expected_ids)
      end

      it "separates the two synthetic groups into different clusters" do
        result   = described_class.new(analysis).call
        clusters = result["patient_clusters"]

        a_labels = clusters.select { |p| p["case_id"].start_with?("A") }
                           .map    { |p| p["cluster"] }
        b_labels = clusters.select { |p| p["case_id"].start_with?("B") }
                           .map    { |p| p["cluster"] }

        expect(a_labels.uniq.size).to eq(1)
        expect(b_labels.uniq.size).to eq(1)
        expect(a_labels.first).not_to eq(b_labels.first)
      end

      it "produces a high silhouette score for cleanly separated groups" do
        result = described_class.new(analysis).call
        expect(result["silhouette_score"]).to be > 0.5
        expect(result["silhouette_score"]).to be <= 1.0
      end

      it "summarizes per-cluster mortality and median age" do
        result = described_class.new(analysis).call
        stats  = result["cluster_stats"]

        expect(stats.size).to eq(2)
        stats.each do |s|
          expect(s).to include("cluster", "n_patients", "n_dead",
                               "mortality_rate", "median_age", "median_survival")
          expect(s["n_patients"]).to eq(n_per_group)
        end

        # All B-cases are dead, all A-cases are alive
        total_dead = stats.sum { |s| s["n_dead"] }
        expect(total_dead).to eq(n_per_group)

        cluster_with_deaths = stats.find { |s| s["n_dead"] > 0 }
        expect(cluster_with_deaths["mortality_rate"]).to eq(1.0)
        expect(cluster_with_deaths["median_age"]).to eq(70.0)
        expect(cluster_with_deaths["median_survival"]).to eq(300.0)
      end

      it "respects the n_top_genes parameter" do
        analysis.update!(params: { "n_clusters" => 2, "n_top_genes" => 2 })
        result = described_class.new(analysis).call

        expect(result["top_genes_used"]).to eq(top_genes.first(2))
        expect(result["n_top_genes"]).to eq(2)
      end

      it "is deterministic across runs (fixed random_seed)" do
        first  = described_class.new(analysis).call
        second = described_class.new(analysis).call

        first_labels  = first["patient_clusters"].map { |p| [ p["case_id"], p["cluster"] ] }
        second_labels = second["patient_clusters"].map { |p| [ p["case_id"], p["cluster"] ] }

        expect(first_labels).to eq(second_labels)
      end
    end

    context "with missing expression values for some genes" do
      before do
        seed_feature_importance

        # 6 cases (>= n_clusters * 2). Some lack one of the genes — service should
        # treat the missing values as 0.0 instead of crashing.
        6.times do |i|
          c = create(:patient_case, dashboard: dashboard, case_id: "M#{i}")
          seed_expression(c.case_id, "GENE1", i.to_f)
          seed_expression(c.case_id, "GENE2", (10 - i).to_f) if i.even?
          # GENE3 missing entirely
        end
      end

      it "still completes and returns labels for every case" do
        result = described_class.new(analysis).call
        expect(result["patient_clusters"].size).to eq(6)
        expect(result["n_cases"]).to eq(6)
      end
    end
  end
end
