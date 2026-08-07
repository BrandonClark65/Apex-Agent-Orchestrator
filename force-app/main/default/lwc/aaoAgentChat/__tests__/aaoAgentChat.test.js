import { createElement } from "lwc";
import AaoAgentChat from "c/aaoAgentChat";
import getAvailableAgents from "@salesforce/apex/AgentChatController.getAvailableAgents";
import sendMessage from "@salesforce/apex/AgentChatController.sendMessage";
import getMySessions from "@salesforce/apex/AgentChatController.getMySessions";
import getSessionState from "@salesforce/apex/AgentChatController.getSessionState";
import { subscribe, isEmpEnabled } from "lightning/empApi";

jest.mock(
  "@salesforce/apex/AgentChatController.getAvailableAgents",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/AgentChatController.sendMessage",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/AgentChatController.getMySessions",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/AgentChatController.getSessionState",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "lightning/empApi",
  () => ({
    subscribe: jest.fn().mockResolvedValue({ id: "sub" }),
    unsubscribe: jest.fn(),
    isEmpEnabled: jest.fn().mockResolvedValue(false)
  }),
  { virtual: true }
);

// eslint-disable-next-line @lwc/lwc/no-async-operation
const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

function mount(props = {}) {
  const el = createElement("c-aao-agent-chat", { is: AaoAgentChat });
  Object.assign(el, props);
  document.body.appendChild(el);
  return el;
}

// One turn that used a tool: user question, activity chip, answer.
const THREAD_WITH_TOOL_ACTIVITY = [
  { role: "user", text: "How many accounts do I have?" },
  { role: "tool", toolName: "QuerySalesforceTool", text: "5 rows" },
  { role: "assistant", text: "You have 5." }
];

describe("c-aao-agent-chat", () => {
  beforeEach(() => {
    // clearAllMocks only clears calls, not implementations, so restore the empApi defaults
    // here - the streaming tests below opt into a live subscription.
    isEmpEnabled.mockResolvedValue(false);
    subscribe.mockResolvedValue({ id: "sub" });

    getAvailableAgents.mockResolvedValue([
      { developerName: "CRUD_Agent", label: "CRUD Agent", goal: "CRUD" }
    ]);
    getMySessions.mockResolvedValue([]);
    sendMessage.mockResolvedValue({
      sessionId: "a01xx0000000001",
      runId: "a00xx0000000001"
    });
    getSessionState.mockResolvedValue({
      sessionId: "a01xx0000000001",
      status: "Active",
      messages: []
    });
  });

  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  it("loads agents and shows the picker", async () => {
    const el = mount();
    await flush();
    await flush();
    const combobox = el.shadowRoot.querySelector("lightning-combobox");
    expect(combobox).not.toBeNull();
    expect(getAvailableAgents).toHaveBeenCalled();
  });

  it("disables Send while the input is empty", async () => {
    const el = mount();
    await flush();
    await flush();

    const sendButton = Array.from(
      el.shadowRoot.querySelectorAll("lightning-button")
    ).find((b) => b.label === "Send");
    expect(sendButton).not.toBeUndefined();
    expect(sendButton.disabled).toBe(true);
  });

  it("calls sendMessage with the chosen agent", async () => {
    const el = mount();
    await flush();
    await flush();

    // reach in via composer events: simulate typed text then Enter key
    const textarea = el.shadowRoot.querySelector("lightning-textarea");
    Object.defineProperty(textarea, "value", {
      value: "Hello agent",
      writable: true
    });
    textarea.dispatchEvent(new CustomEvent("change"));
    await flush();

    textarea.dispatchEvent(
      new KeyboardEvent("keydown", { key: "Enter", shiftKey: false })
    );
    await flush();

    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        agentDeveloperName: "CRUD_Agent",
        sessionId: null,
        message: "Hello agent"
      })
    );
  });

  describe("Show Agent Activity", () => {
    // Opens an existing thread whose history includes a tool round-trip.
    async function openThreadWithToolActivity(props) {
      getMySessions.mockResolvedValue([
        {
          sessionId: "a01xx0000000001",
          agentDeveloperName: "CRUD_Agent",
          status: "Active",
          title: "Accounts"
        }
      ]);
      getSessionState.mockResolvedValue({
        sessionId: "a01xx0000000001",
        status: "Active",
        messages: THREAD_WITH_TOOL_ACTIVITY
      });

      const el = mount(props);
      await flush();
      await flush();

      el.shadowRoot.querySelector("li[data-id]").click();
      await flush();
      await flush();
      return el;
    }

    // Subscribes for real so a StepCompleted event can be pushed at the component, and hands
    // back the callback empApi would call.
    function captureStreamingHandler() {
      const captured = {};
      isEmpEnabled.mockResolvedValue(true);
      subscribe.mockImplementation((channel, replayId, callback) => {
        captured.fire = callback;
        return Promise.resolve({ id: "sub" });
      });
      return captured;
    }

    function stepCompletedOn(toolName) {
      return {
        data: {
          payload: {
            aao__Session_Id__c: "a01xx0000000001",
            aao__Event_Type__c: "StepCompleted",
            aao__Payload_Json__c: JSON.stringify({ toolName })
          }
        }
      };
    }

    function renderedRoles(el) {
      return Array.from(
        el.shadowRoot.querySelectorAll("c-aao-chat-message")
      ).map((m) => m.message.role);
    }

    function progressText(el) {
      return el.shadowRoot.querySelector('[data-id="thinking-text"]')
        .textContent;
    }

    it("shows tool activity chips by default", async () => {
      // The property is absent, exactly as it is for a page laid out before it existed.
      const el = await openThreadWithToolActivity({});
      expect(renderedRoles(el)).toEqual(["user", "tool", "assistant"]);
    });

    it("hides tool activity chips when switched off", async () => {
      const el = await openThreadWithToolActivity({ showToolActivity: false });
      expect(renderedRoles(el)).toEqual(["user", "assistant"]);
    });

    it("re-renders an open thread when the property flips", async () => {
      const el = await openThreadWithToolActivity({ showToolActivity: false });
      expect(renderedRoles(el)).toEqual(["user", "assistant"]);

      el.showToolActivity = true;
      await flush();

      expect(renderedRoles(el)).toEqual(["user", "tool", "assistant"]);
    });

    it("names the tool in the progress text when switched on", async () => {
      const emp = captureStreamingHandler();
      const el = await openThreadWithToolActivity({ showToolActivity: true });

      emp.fire(stepCompletedOn("QuerySalesforceTool"));
      await flush();

      expect(progressText(el)).toBe("Calling QuerySalesforceTool…");
    });

    it("keeps the tool name out of the progress text when switched off", async () => {
      const emp = captureStreamingHandler();
      const el = await openThreadWithToolActivity({ showToolActivity: false });

      emp.fire(stepCompletedOn("QuerySalesforceTool"));
      await flush();

      expect(progressText(el)).toBe("Thinking…");
    });
  });
});
