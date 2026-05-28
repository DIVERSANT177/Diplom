FactoryBot.define do
  factory :analysis do
    algorithm { "feature_importance" }
    status    { "pending" }
    params    { {} }
    result    { {} }
    association :dashboard

    trait :ready do
      status { "ready" }
    end

    trait :running do
      status { "running" }
    end

    trait :feature_importance_ready do
      algorithm { "feature_importance" }
      status    { "ready" }
      result do
        {
          "top_genes" => (1..10).map { |i| { "gene" => "GENE#{i}", "importance" => 1.0 / i } }
        }
      end
    end

    trait :clustering do
      algorithm { "clustering" }
      params    { { "n_clusters" => 2, "n_top_genes" => 3 } }
    end

    trait :survival do
      algorithm { "survival" }
      params    { { "n_top_genes" => 3, "model_type" => "ridge", "reg_param" => 1.0 } }
    end
  end
end
