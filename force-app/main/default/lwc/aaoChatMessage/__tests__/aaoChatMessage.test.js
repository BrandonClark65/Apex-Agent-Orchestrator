import { createElement } from "lwc";
import AaoChatMessage from "c/aaoChatMessage";

function render(message) {
  const el = createElement("c-aao-chat-message", { is: AaoChatMessage });
  el.message = message;
  document.body.appendChild(el);
  return el;
}

describe("c-aao-chat-message", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
  });

  it("renders a user bubble as outbound", () => {
    const el = render({ role: "user", text: "Find my accounts" });
    const item = el.shadowRoot.querySelector("li");
    expect(item.className).toContain("slds-chat-listitem_outbound");
    expect(el.shadowRoot.textContent).toContain("Find my accounts");
  });

  it("renders an assistant bubble as inbound", () => {
    const el = render({ role: "assistant", text: "Here you go" });
    const item = el.shadowRoot.querySelector("li");
    expect(item.className).toContain("slds-chat-listitem_inbound");
    expect(el.shadowRoot.textContent).toContain("Here you go");
  });

  it("renders a tool activity chip", () => {
    const el = render({ role: "tool", toolName: "QuerySalesforceTool" });
    expect(el.shadowRoot.textContent).toContain("Used QuerySalesforceTool");
    expect(
      el.shadowRoot.querySelector(".slds-chat-listitem_event")
    ).not.toBeNull();
  });

  it("renders structured data beside an assistant answer", () => {
    const el = render({
      role: "assistant",
      text: "It ships Thursday.",
      data: { orderId: "801xx", status: "Shipped" }
    });
    expect(el.shadowRoot.textContent).toContain("It ships Thursday.");
    expect(el.shadowRoot.querySelector(".message-data")).not.toBeNull();
    const rows = el.shadowRoot.querySelectorAll(".data-row");
    expect(rows.length).toBe(2);
    expect(el.shadowRoot.textContent).toContain("orderId");
    expect(el.shadowRoot.textContent).toContain("801xx");
    expect(el.shadowRoot.textContent).toContain("status");
    expect(el.shadowRoot.textContent).toContain("Shipped");
  });

  it("omits the data block when an assistant answer has no data", () => {
    const el = render({ role: "assistant", text: "Done." });
    expect(el.shadowRoot.querySelector(".message-data")).toBeNull();
  });
});
