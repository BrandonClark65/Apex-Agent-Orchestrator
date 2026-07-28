import { LightningElement, track } from "lwc";
import getAgents from "@salesforce/apex/AgentBuilderController.getAgents";
import getTestCases from "@salesforce/apex/AgentBuilderController.getTestCases";
import saveTestCase from "@salesforce/apex/AgentBuilderController.saveTestCase";
import testRunOnVersion from "@salesforce/apex/AgentBuilderController.testRunOnVersion";
import getPromptVersions from "@salesforce/apex/AgentBuilderController.getPromptVersions";

const ACTIVE_VERSION = "";

/**
 * Test bench: pick an agent, edit an input JSON (or load a saved sample), run it for
 * real, and watch the live step trace via the embedded run-detail component. Saved
 * samples live in Test_Case__c records.
 *
 * The prompt-version picker is what makes this a comparison tool rather than just a runner:
 * run the same saved input against v3 and then v4 and put the two traces side by side.
 */
export default class AaoTestBench extends LightningElement {
  agents = [];
  @track testCases = [];
  @track versions = [];
  selectedAgent = null;
  selectedCaseId = null;
  selectedVersionId = ACTIVE_VERSION;
  inputJson = '{"task": ""}';
  caseName = "";
  runId = null;
  errorText = null;

  async connectedCallback() {
    try {
      this.agents = await getAgents();
      if (this.agents.length) {
        this.selectedAgent = this.agents[0].developerName;
        await Promise.all([this.loadCases(), this.loadVersions()]);
      }
    } catch (e) {
      this.errorText = this.reduceError(e);
    }
  }

  async loadCases() {
    this.testCases = await getTestCases({
      agentDeveloperName: this.selectedAgent
    });
    this.selectedCaseId = null;
  }

  async loadVersions() {
    // Drafts are included deliberately: trying a candidate prompt before publishing it is the
    // whole point of the picker. Publishing also activates, so excluding drafts would mean the
    // only way to evaluate one was to ship it to everyone first.
    this.versions = await getPromptVersions({
      agentDeveloperName: this.selectedAgent
    });
    this.selectedVersionId = ACTIVE_VERSION;
  }

  get agentOptions() {
    return this.agents.map((a) => ({
      label: a.label,
      value: a.developerName
    }));
  }

  get caseOptions() {
    return this.testCases.map((c) => ({
      label: c.name,
      value: c.testCaseId
    }));
  }

  get hasCases() {
    return this.testCases.length > 0;
  }

  get versionOptions() {
    return [
      { label: "Active version", value: ACTIVE_VERSION },
      ...this.versions.map((v) => ({
        label: `v${v.versionNumber}${this.versionSuffix(v)}`,
        value: v.versionId
      }))
    ];
  }

  get hasVersions() {
    return this.versions.length > 0;
  }

  versionSuffix(version) {
    if (version.isActive) {
      return " (active)";
    }
    return version.status === "Draft" ? " (draft)" : "";
  }

  get runDisabled() {
    return !this.selectedAgent || !(this.inputJson || "").trim();
  }

  get saveDisabled() {
    return this.runDisabled || !(this.caseName || "").trim();
  }

  async handleAgentChange(event) {
    this.selectedAgent = event.detail.value;
    this.runId = null;
    await Promise.all([this.loadCases(), this.loadVersions()]);
  }

  handleVersionChange(event) {
    this.selectedVersionId = event.detail.value;
  }

  handleCaseChange(event) {
    this.selectedCaseId = event.detail.value;
    const tc = this.testCases.find((c) => c.testCaseId === this.selectedCaseId);
    if (tc) {
      this.inputJson = tc.inputJson;
    }
  }

  handleInputChange(event) {
    this.inputJson = event.target.value;
  }

  handleNameChange(event) {
    this.caseName = event.target.value;
  }

  async handleSave() {
    try {
      this.errorText = null;
      await saveTestCase({
        agentDeveloperName: this.selectedAgent,
        name: this.caseName,
        inputJson: this.inputJson
      });
      this.caseName = "";
      await this.loadCases();
    } catch (e) {
      this.errorText = this.reduceError(e);
    }
  }

  async handleRun() {
    try {
      this.errorText = null;
      JSON.parse(this.inputJson); // fail fast on malformed JSON
    } catch (e) {
      this.errorText = "Input is not valid JSON: " + e.message;
      return;
    }
    try {
      this.runId = null;
      this.runId = await testRunOnVersion({
        agentDeveloperName: this.selectedAgent,
        inputJson: this.inputJson,
        // Empty string means "whatever is active" — Apex takes null for that.
        promptVersionId: this.selectedVersionId || null
      });
    } catch (e) {
      this.errorText = this.reduceError(e);
    }
  }

  reduceError(e) {
    return e?.body?.message || e?.message || "Something went wrong.";
  }
}
