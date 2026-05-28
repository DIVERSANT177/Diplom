require "prawn"
require "prawn/table"

class DashboardPdfExporter
  FONT_REGULAR = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
  FONT_BOLD    = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
  FONT_ITALIC  = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Oblique.ttf"

  CHART_COLORS = %w[6366f1 f472b6 22c55e f59e0b ef4444 06b6d4 a855f7 84cc16].freeze

  def initialize(dashboard, locale: I18n.locale, heatmap_png_path: nil)
    @dashboard        = dashboard
    @locale           = locale
    @heatmap_png_path = heatmap_png_path
  end

  def call
    I18n.with_locale(@locale) do
      FileUtils.mkdir_p(File.dirname(@dashboard.pdf_file_path))

      Prawn::Document.generate(@dashboard.pdf_file_path.to_s, page_size: "A4", margin: 40) do |pdf|
        register_fonts(pdf)
        pdf.font "DejaVu"

        render_header(pdf)
        render_meta(pdf)
        render_clinical_summary(pdf) if @dashboard.visualizations.include?("clinical_summary")
        render_kaplan_meier(pdf)     if @dashboard.visualizations.include?("kaplan_meier")
        render_heatmap_summary(pdf)  if @dashboard.visualizations.include?("heatmap")
        render_footer(pdf)
      end

      @dashboard.pdf_file_path.to_s
    end
  end

  private

  def register_fonts(pdf)
    pdf.font_families.update(
      "DejaVu" => {
        normal: font_path(FONT_REGULAR),
        bold:   font_path(FONT_BOLD),
        italic: font_path(FONT_ITALIC)
      }
    )
  end

  def font_path(path)
    File.exist?(path) ? path : FONT_REGULAR
  end

  def render_header(pdf)
    pdf.text @dashboard.title.to_s, size: 22, style: :bold
    pdf.move_down 4
    pdf.text @dashboard.projects.to_a.join(", "), size: 11, color: "6b7280"
    pdf.move_down 12
    pdf.stroke_color "e5e7eb"
    pdf.stroke_horizontal_rule
    pdf.stroke_color "000000"
    pdf.move_down 16
  end

  def render_meta(pdf)
    pdf.text t("pdf.overview"), size: 14, style: :bold
    pdf.move_down 8

    rows = [
      [ t("dashboards.fields.status"),            t("dashboards.status.#{@dashboard.status}") ],
      [ t("dashboards.fields.total_cases"),       @dashboard.total_cases.to_s ],
      [ t("dashboards.fields.projects"),          @dashboard.projects.to_a.join(", ") ],
      [ t("dashboards.fields.survival_endpoint"), @dashboard.survival_endpoint.to_s ],
      [ t("dashboards.fields.stratify_by"),       @dashboard.stratify_by.presence || t("common.not_selected") ],
      [ t("dashboards.fields.top_genes_count"),   @dashboard.top_genes_count.to_s ],
      [ t("dashboards.fields.visualizations"),    @dashboard.visualizations.to_a.map { |v| Dashboard.visualization_label(v) }.join(", ") ],
      [ t("dashboards.fields.created_at"),        I18n.l(@dashboard.created_at, format: :short) ]
    ]

    styled_table(pdf, rows, label_width: 180)
    pdf.move_down 18
  end

  def render_clinical_summary(pdf)
    pdf.text t("dashboards.visualizations.clinical_summary"), size: 14, style: :bold
    pdf.move_down 8

    cases = @dashboard.cases
    gender_counts = cases.where.not(gender: nil).group(:gender).count
    vital_counts  = cases.where.not(vital_status: nil).group(:vital_status).count
    ages          = cases.where.not(age_at_index: nil).pluck(:age_at_index)

    age_groups = { "< 40" => 0, "40-60" => 0, "> 60" => 0 }
    ages.each do |age|
      key = age < 40 ? "< 40" : age <= 60 ? "40-60" : "> 60"
      age_groups[key] += 1
    end

    [
      [ t("dashboards.show.gender"),        gender_counts ],
      [ t("dashboards.show.vital_status"),  vital_counts ],
      [ t("dashboards.show.age_groups"),    age_groups ]
    ].each do |title, data|
      pdf.text title, size: 11, style: :bold, color: "374151"
      pdf.move_down 4

      if data.empty?
        pdf.text t("common.no_data"), size: 10, color: "9ca3af"
      else
        rows = data.map { |k, v| [ k.to_s, v.to_s ] }
        styled_table(pdf, rows, label_width: 220)
      end
      pdf.move_down 10
    end
  end

  def render_kaplan_meier(pdf)
    pdf.start_new_page if pdf.cursor < 260

    pdf.text "#{t('dashboards.visualizations.kaplan_meier')} (#{@dashboard.survival_endpoint})", size: 14, style: :bold
    pdf.move_down 8

    cases = @dashboard.cases.where.not(vital_status: nil)
    if @dashboard.stratify_by.present?
      cases = cases.where.not(@dashboard.stratify_by => nil)
    end

    if cases.empty?
      pdf.text t("common.no_data"), size: 10, color: "9ca3af"
      pdf.move_down 12
      return
    end

    km = KaplanMeierCalculator.new(
      cases,
      stratify_by: @dashboard.stratify_by
    ).call

    draw_km_chart(pdf, km)
    pdf.move_down 10
    draw_km_summary(pdf, km)
    pdf.move_down 14
  end

  def draw_km_chart(pdf, km)
    chart_height = 220
    chart_width  = pdf.bounds.width
    top_y        = pdf.cursor
    origin_x     = 40
    origin_y     = top_y - chart_height

    max_time = km.values.flat_map { |pts| pts.map { |p| p[:time] } }.max.to_f
    max_time = 1.0 if max_time.zero?

    pdf.stroke_color "cbd5e1"
    pdf.line_width 0.5
    (0..4).each do |i|
      y = origin_y + (chart_height - 20) * i / 4.0
      pdf.stroke_horizontal_line origin_x, origin_x + chart_width - 20, at: y
      pdf.fill_color "6b7280"
      pdf.text_box "#{(i * 25)}%", at: [ 0, y + 4 ], width: 35, size: 8, align: :right
    end

    pdf.stroke_color "374151"
    pdf.line_width 1
    pdf.stroke_line [ origin_x, origin_y ], [ origin_x, top_y - 4 ]
    pdf.stroke_line [ origin_x, origin_y ], [ origin_x + chart_width - 20, origin_y ]

    km.each_with_index do |(group, points), idx|
      color = CHART_COLORS[idx % CHART_COLORS.size]
      pdf.stroke_color color
      pdf.line_width 1.3

      prev = nil
      points.each do |p|
        x = origin_x + (p[:time] / max_time) * (chart_width - 20)
        y = origin_y + p[:survival] * (chart_height - 20)
        if prev
          pdf.stroke_line [ prev[0], prev[1] ], [ x, prev[1] ]
          pdf.stroke_line [ x, prev[1] ], [ x, y ]
        end
        prev = [ x, y ]
      end
    end

    pdf.stroke_color "000000"
    pdf.fill_color "000000"
    pdf.line_width 1

    pdf.move_cursor_to origin_y - 6
    pdf.fill_color "6b7280"
    pdf.text "0  —  #{max_time.to_i} #{t('common.days_short')}", size: 8, align: :center
    pdf.fill_color "000000"
    pdf.move_down 6

    pdf.bounding_box([ 0, pdf.cursor ], width: chart_width) do
      km.each_with_index do |(group, _), idx|
        color = CHART_COLORS[idx % CHART_COLORS.size]
        pdf.fill_color color
        pdf.fill_rectangle [ 0, pdf.cursor ], 10, 10
        pdf.fill_color "374151"
        pdf.draw_text " #{group}", at: [ 14, pdf.cursor - 9 ], size: 9
        pdf.move_down 14
      end
    end
    pdf.fill_color "000000"
  end

  def draw_km_summary(pdf, km)
    rows = [ [ t("pdf.group"), t("pdf.n_points"), t("pdf.median_survival") ] ]
    km.each do |group, points|
      median = points.find { |p| p[:survival] <= 0.5 }
      rows << [
        group.to_s,
        points.size.to_s,
        median ? "#{median[:time]} #{t('common.days_short')}" : t("common.no_data")
      ]
    end

    pdf.table(rows, header: true, cell_style: { size: 9, padding: 4, border_width: 0.5, border_color: "e5e7eb" }) do
      row(0).font_style = :bold
      row(0).background_color = "f3f4f6"
    end
  end

  def render_heatmap_summary(pdf)
    pdf.start_new_page if pdf.cursor < 260

    pdf.text t("dashboards.visualizations.heatmap"), size: 14, style: :bold
    pdf.move_down 8

    expression_scope = @dashboard.gene_expressions
    n_samples = expression_scope.distinct.count(:case_id)
    n_genes   = expression_scope.distinct.count(:gene_id)

    rows = [
      [ t("dashboards.show.samples"),           n_samples.to_s ],
      [ t("dashboards.show.genes"),             n_genes.to_s ],
      [ t("dashboards.fields.top_genes_count"), @dashboard.top_genes_count.to_s ],
      [ t("pdf.expression_status"),             t("pdf.expression_#{@dashboard.expression_status}") ]
    ]
    styled_table(pdf, rows, label_width: 220)
    pdf.move_down 12

    render_heatmap_image(pdf)
  end

  def render_heatmap_image(pdf)
    return unless @heatmap_png_path && File.exist?(@heatmap_png_path) && File.size(@heatmap_png_path) > 0

    pdf.start_new_page if pdf.cursor < 280

    pdf.text t("pdf.heatmap_snapshot"), size: 11, style: :bold, color: "374151"
    pdf.move_down 6

    max_w = pdf.bounds.width
    max_h = [ pdf.cursor - 30, 420 ].min
    pdf.image @heatmap_png_path, fit: [ max_w, max_h ], position: :center
    pdf.move_down 10
  rescue => e
    Rails.logger.warn("Heatmap image embed failed: #{e.message}")
  end

  def render_footer(pdf)
    pdf.number_pages(
      "#{t('pdf.generated_at', time: I18n.l(Time.current, format: :short))}  —  <page> / <total>",
      at: [ 0, 0 ], width: pdf.bounds.width, align: :center, size: 8, start_count_at: 1
    )
  end

  def styled_table(pdf, rows, label_width: 160)
    pdf.table(rows, cell_style: { size: 10, padding: 4, border_width: 0 }) do
      column(0).font_style = :bold
      column(0).width = label_width
      column(0).text_color = "6b7280"
    end
  end

  def t(*args, **opts)
    I18n.t(*args, **opts)
  end
end
