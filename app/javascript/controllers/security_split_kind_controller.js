import { Controller } from "@hotwired/stimulus";

// Shows the percentage field for a stock dividend or the ratio fields for a
// split, whichever the form is set to.
export default class extends Controller {
  static targets = ["kind", "stockDividend", "split"];

  connect() {
    this.toggle();
  }

  toggle() {
    const stockDividend = this.kindTarget.value === "stock_dividend";
    this.stockDividendTarget.classList.toggle("hidden", !stockDividend);
    this.splitTarget.classList.toggle("hidden", stockDividend);
  }
}
