FactoryBot.define do
  factory :patient_case, class: "Case" do
    sequence(:case_id) { |n| "TCGA-CASE-#{format('%05d', n)}" }
    project_id { "TCGA-BRCA" }
    gender { "female" }
    age_at_index { 60 }
    tumor_stage { "Stage II" }
    vital_status { "Alive" }
    days_to_death { nil }
    days_to_last_follow_up { 1000.0 }
    association :dashboard

    trait :dead do
      vital_status { "Dead" }
      days_to_death { 500.0 }
      days_to_last_follow_up { nil }
    end

    trait :alive do
      vital_status { "Alive" }
      days_to_death { nil }
      days_to_last_follow_up { 1500.0 }
    end
  end
end
