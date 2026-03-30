class Case < ApplicationRecord
  belongs_to :dashboard

  VITAL_STATUSES = %w[Alive Dead].freeze

  scope :alive, -> { where(vital_status: "Alive") }
  scope :dead,  -> { where(vital_status: "Dead") }
  scope :by_gender,  ->(gender) { where(gender: gender) }
  scope :by_project, ->(project_id) { where(project_id: project_id) }
end
