class KaplanMeierCalculator
  def initialize(cases, stratify_by: nil, endpoint: "OS")
    @cases = cases
    @stratify_by = stratify_by
    @endpoint = endpoint
  end

  def call
    if @stratify_by.present?
      groups = @cases.group_by { |c| c.send(@stratify_by) }
      groups.transform_values { |group_cases| calculate(group_cases) }
    else
      { "Все пациенты" => calculate(@cases.to_a) }
    end
  end

  private

  def calculate(cases)
    events = cases.map do |c|
      if @endpoint == "OS"
        time  = c.vital_status == "Dead" ? c.days_to_death : c.days_to_last_follow_up
        event = c.vital_status == "Dead" ? 1 : 0
      else
        time  = c.days_to_last_follow_up
        event = c.vital_status == "Dead" ? 1 : 0
      end
      [ time, event ]
    end.reject { |time, _| time.nil? || time < 0 }.sort_by(&:first)

    n = events.size
    survival = 1.0
    result = [ { time: 0, survival: 1.0 } ]

    events.group_by(&:first).each do |time, group|
      deaths = group.sum(&:last)
      survival *= (1.0 - deaths.to_f / n)
      n -= group.size
      result << { time: time.to_i, survival: survival.round(4) }
    end

    result
  end
end
