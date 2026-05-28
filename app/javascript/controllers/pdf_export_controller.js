import { Controller } from "@hotwired/stimulus"

// Captures the currently-rendered Plotly heatmap as a PNG data URL and stuffs it
// into a hidden field, so the PDF export job can embed exactly what the user sees.
export default class extends Controller {
  static targets = ["heatmapField"]

  async capture(event) {
    if (this.captured) return

    const chartEl = document.getElementById("heatmapChart")
    const hasChart =
      chartEl &&
      chartEl.style.display !== "none" &&
      typeof Plotly !== "undefined" &&
      chartEl.data

    if (!hasChart) return

    event.preventDefault()

    try {
      const dataUrl = await Plotly.toImage(chartEl, {
        format: "png",
        width: 1400,
        height: 700
      })
      if (this.hasHeatmapFieldTarget) {
        this.heatmapFieldTarget.value = dataUrl
      }
    } catch (err) {
      console.warn("Heatmap capture failed, proceeding without snapshot:", err)
    }

    this.captured = true
    event.target.requestSubmit()
  }
}
