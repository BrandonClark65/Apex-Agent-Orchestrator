import { LightningElement, track } from "lwc";
import { subscribe, unsubscribe, isEmpEnabled } from "lightning/empApi";
import getAgents from "@salesforce/apex/AgentBuilderController.getAgents";
import getManifestPreview from "@salesforce/apex/AgentBuilderController.getManifestPreview";
import getToolCatalog from "@salesforce/apex/AgentBuilderController.getToolCatalog";
import getProviderOptions from "@salesforce/apex/AgentBuilderController.getProviderOptions";
import getMemoryConfigOptions from "@salesforce/apex/AgentBuilderController.getMemoryConfigOptions";
import saveAgent from "@salesforce/apex/AgentBuilderController.saveAgent";
import getPromptVersions from "@salesforce/apex/AgentBuilderController.getPromptVersions";
import savePromptVersion from "@salesforce/apex/AgentBuilderController.savePromptVersion";
import updatePromptVersion from "@salesforce/apex/AgentBuilderController.updatePromptVersion";
import activatePromptVersion from "@salesforce/apex/AgentBuilderController.activatePromptVersion";
import publishPromptVersion from "@salesforce/apex/AgentBuilderController.publishPromptVersion";
import restorePromptVersionAsDraft from "@salesforce/apex/AgentBuilderController.restorePromptVersionAsDraft";
import { diffRows, diffStats } from "c/aaoPromptDiff";

const UI_EVENT_CHANNEL = "/event/aao__Agent_UI_Event__e";
const DEPLOY_TIMEOUT_MS = 90000;

/**
 * Agent configuration viewer and editor.
 *
 * Two save paths, deliberately different: agent *configuration* (provider, memory, step cap,
 * tool grants) is Custom Metadata, so Deploy submits a real Metadata API deployment and waits
 * for a DeployFinished event on Agent_UI_Event__e. The system *prompt* is not — it lives in
 * Agent_Prompt_Version__c records, so saving or rolling back a prompt is ordinary DML and
 * commits immediately.
 */
export default class AaoAgentBuilder extends LightningElement {
  @track agents = [];
  selected = null;
  manifest = null;
  errorText = null;

  // edit mode
  editing = false;
  isNew = false;
  @track form = {};
  @track toolRows = [];
  providerOptions = [];
  memoryOptions = [];
  deploying = false;
  deployJobId = null;
  deployMessage = null;

  // prompt versions
  @track versions = [];
  versionsLoading = false;
  promptDraft = "";
  changeNote = "";
  publishNow = true;
  savingPrompt = false;
  promptMessage = null;
  editingPrompt = false;
  // Id of the draft being edited in place; null means the editor will create a new version.
  editingVersionId = null;
  @track diff = null;

  _subscription = null;
  _deployTimer = null;

  async connectedCallback() {
    try {
      const [providers, memories] = await Promise.all([
        getProviderOptions(),
        getMemoryConfigOptions()
      ]);
      this.providerOptions = providers.map((p) => ({
        label: p,
        value: p
      }));
      this.memoryOptions = memories.map((m) => ({ label: m, value: m }));
      await this.loadAgents();
      const enabled = await isEmpEnabled();
      if (enabled) {
        this._subscription = await subscribe(UI_EVENT_CHANNEL, -1, (event) =>
          this.handleUiEvent(event)
        );
      }
    } catch (e) {
      this.errorText = this.reduceError(e);
    }
  }

  disconnectedCallback() {
    if (this._subscription) {
      unsubscribe(this._subscription);
      this._subscription = null;
    }
    this.clearDeployTimer();
  }

  async loadAgents() {
    this.agents = (await getAgents()).map((a) => ({
      ...a,
      cssClass: "agent-item",
      statusLabel: a.isActive ? "Active" : "Inactive",
      badgeClass: a.isActive ? "slds-badge slds-theme_success" : "slds-badge"
    }));
    if (this.agents.length && !this.selected) {
      this.select(this.agents[0].developerName);
    } else if (this.selected) {
      this.select(this.selected.developerName);
    }
  }

  handleSelect(event) {
    this.editing = false;
    this.select(event.currentTarget.dataset.name);
  }

  select(developerName) {
    this.manifest = null;
    this.selected =
      this.agents.find((a) => a.developerName === developerName) || null;
    this.agents = this.agents.map((a) => ({
      ...a,
      cssClass:
        a.developerName === developerName ? "agent-item selected" : "agent-item"
    }));
    this.resetPromptPanel();
    if (this.selected) {
      this.loadVersions();
    }
  }

  async handleShowManifest() {
    try {
      this.manifest = await getManifestPreview({
        agentDeveloperName: this.selected.developerName
      });
    } catch (e) {
      this.errorText = this.reduceError(e);
    }
  }

  // ── edit mode ───────────────────────────────────────────────

  async handleEdit() {
    await this.enterEdit(false);
  }

  async handleNew() {
    await this.enterEdit(true);
  }

  async enterEdit(isNew) {
    try {
      this.errorText = null;
      this.deployMessage = null;
      this.isNew = isNew;
      const source = isNew ? null : this.selected;
      this.form = {
        developerName: source?.developerName ?? "",
        label: source?.label ?? "",
        goal: source?.goal ?? "",
        systemPrompt: source?.systemPrompt ?? "",
        llmProvider: source?.llmProvider ?? this.providerOptions[0]?.value,
        maxSteps: source?.maxSteps ?? 10,
        memoryConfig: source?.memoryConfig ?? this.memoryOptions[0]?.value,
        isActive: source ? source.isActive : true,
        requiredCustomPermission: source?.requiredCustomPermission ?? ""
      };
      const catalog = await getToolCatalog();
      const granted = new Set(
        (source?.tools ?? []).map((t) => t.developerName)
      );
      this.toolRows = catalog.map((t) => ({
        developerName: t.developerName,
        label: t.label,
        description: t.description,
        allowed: granted.has(t.developerName)
      }));
      this.editing = true;
    } catch (e) {
      this.errorText = this.reduceError(e);
    }
  }

  handleCancelEdit() {
    this.editing = false;
    this.deployMessage = null;
  }

  handleFormChange(event) {
    const { field } = event.target.dataset;
    const value =
      event.target.type === "checkbox"
        ? event.target.checked
        : (event.detail?.value ?? event.target.value);
    this.form = { ...this.form, [field]: value };
  }

  handleToolToggle(event) {
    const name = event.target.dataset.name;
    this.toolRows = this.toolRows.map((t) => {
      return t.developerName === name
        ? { ...t, allowed: event.target.checked }
        : t;
    });
  }

  async handleDeploy() {
    try {
      this.errorText = null;
      this.deploying = true;
      this.deployMessage = "Submitting metadata deployment…";

      const request = {
        ...this.form,
        maxSteps: parseInt(this.form.maxSteps, 10) || 10,
        // A new agent seeds the packaged CMDT baseline; an existing agent's prompt is
        // owned by its versions, so leave the baseline out of the deploy entirely.
        // The controller enforces this too — this just avoids shipping dead payload.
        systemPrompt: this.isNew ? this.form.systemPrompt : null,
        tools: this.toolRows.map((t) => ({
          toolDeveloperName: t.developerName,
          allowed: t.allowed
        }))
      };
      this.deployJobId = await saveAgent({
        requestJson: JSON.stringify(request)
      });
      this.deployMessage = "Deploying… (this usually takes a few seconds)";

      // Fallback if the completion event never arrives (empApi off, etc.)
      // eslint-disable-next-line @lwc/lwc/no-async-operation
      this._deployTimer = setTimeout(() => {
        if (this.deploying) {
          this.finishDeploy(
            true,
            "Deployment submitted. Refresh to see the result."
          );
        }
      }, DEPLOY_TIMEOUT_MS);
    } catch (e) {
      this.deploying = false;
      this.deployMessage = null;
      this.errorText = this.reduceError(e);
    }
  }

  handleUiEvent(event) {
    const payload = event?.data?.payload ?? {};
    const eventType = payload.aao__Event_Type__c ?? payload.Event_Type__c ?? "";
    if (eventType !== "DeployFinished" || !this.deploying) {
      return;
    }
    const runId = payload.aao__Run_Id__c ?? payload.Run_Id__c ?? "";
    if (this.deployJobId && !this.deployJobId.startsWith(runId)) {
      return;
    }
    let detail = {};
    try {
      detail = JSON.parse(
        payload.aao__Payload_Json__c ?? payload.Payload_Json__c ?? "{}"
      );
    } catch {
      detail = {};
    }
    if (detail.succeeded) {
      this.finishDeploy(true, "Deployed successfully.");
    } else {
      this.finishDeploy(
        false,
        "Deployment failed: " + (detail.errors?.join("; ") || "unknown error")
      );
    }
  }

  async finishDeploy(succeeded, message) {
    this.clearDeployTimer();
    this.deploying = false;
    this.deployMessage = message;
    if (succeeded) {
      this.editing = false;
      await this.loadAgents();
    }
  }

  clearDeployTimer() {
    if (this._deployTimer) {
      clearTimeout(this._deployTimer);
      this._deployTimer = null;
    }
  }

  // ── prompt versions ─────────────────────────────────────────

  resetPromptPanel() {
    this.versions = [];
    this.diff = null;
    this.editingPrompt = false;
    this.promptMessage = null;
    this.promptDraft = "";
    this.changeNote = "";
    this.publishNow = true;
  }

  async loadVersions() {
    const agent = this.selected?.developerName;
    if (!agent) {
      return;
    }
    try {
      this.versionsLoading = true;
      const rows = await getPromptVersions({
        agentDeveloperName: agent
      });
      // The selected agent can change while this await is in flight.
      if (this.selected?.developerName !== agent) {
        return;
      }
      this.versions = rows.map((v) => this.decorateVersion(v));
    } catch (e) {
      this.errorText = this.reduceError(e);
    } finally {
      this.versionsLoading = false;
    }
  }

  decorateVersion(version) {
    const published = version.status === "Published";
    return {
      ...version,
      versionLabel: `v${version.versionNumber}`,
      statusBadgeClass: version.isActive
        ? "slds-badge slds-theme_success"
        : "slds-badge",
      statusLabel: version.isActive ? "Active" : version.status,
      // Only a published, non-active version can be rolled back to.
      canActivate: published && !version.isActive,
      canPublish: version.status === "Draft",
      // Drafts are the only editable versions; published bodies are frozen.
      canEdit: version.status === "Draft",
      // Restoring a draft would just clone an editable thing into another editable thing.
      canRestore: version.status !== "Draft",
      createdSummary: version.createdByName ? `${version.createdByName}` : ""
    };
  }

  // "Edit prompt": start a brand-new version from whatever is live today.
  handleEditPrompt() {
    this.promptMessage = null;
    this.diff = null;
    this.editingVersionId = null;
    this.promptDraft = this.selected?.systemPrompt ?? "";
    this.changeNote = "";
    this.publishNow = true;
    this.editingPrompt = true;
  }

  // "Edit draft": refine an existing draft in place rather than spawning another version.
  handleEditDraft(event) {
    const versionId = event.currentTarget.dataset.id;
    this.openDraftForEditing(
      this.versions.find((v) => v.versionId === versionId)
    );
  }

  openDraftForEditing(version) {
    if (!version) {
      return;
    }
    this.promptMessage = null;
    this.diff = null;
    this.editingVersionId = version.versionId;
    this.promptDraft = version.systemPrompt ?? "";
    this.changeNote = version.changeNote ?? "";
    // A draft is by definition not live yet; don't default to shipping it on save.
    this.publishNow = false;
    this.editingPrompt = true;
  }

  handleCancelPrompt() {
    this.editingPrompt = false;
    this.editingVersionId = null;
    this.promptMessage = null;
  }

  handlePromptDraftChange(event) {
    this.promptDraft = event.detail?.value ?? event.target.value;
  }

  handleChangeNoteChange(event) {
    this.changeNote = event.detail?.value ?? event.target.value;
  }

  handlePublishNowChange(event) {
    this.publishNow = event.target.checked;
  }

  async handleSavePrompt() {
    try {
      this.savingPrompt = true;
      this.errorText = null;

      if (this.editingVersionId) {
        // Editing an existing draft: update it rather than inserting another version.
        await updatePromptVersion({
          versionId: this.editingVersionId,
          systemPrompt: this.promptDraft,
          goal: this.selected.goal,
          changeNote: this.changeNote
        });
        if (this.publishNow) {
          await publishPromptVersion({ versionId: this.editingVersionId });
        }
        this.promptMessage = this.publishNow
          ? "Draft updated, published and active."
          : "Draft updated.";
      } else {
        await savePromptVersion({
          agentDeveloperName: this.selected.developerName,
          systemPrompt: this.promptDraft,
          goal: this.selected.goal,
          changeNote: this.changeNote,
          publishNow: this.publishNow,
          sourceVersionId: this.selected.activePromptVersionId ?? null
        });
        this.promptMessage = this.publishNow
          ? "New version published and active."
          : "Draft saved. Edit or publish it from the list below.";
      }

      this.editingPrompt = false;
      this.editingVersionId = null;
      await this.refreshAfterVersionChange();
    } catch (e) {
      this.errorText = this.reduceError(e);
    } finally {
      this.savingPrompt = false;
    }
  }

  async handleActivateVersion(event) {
    try {
      this.errorText = null;
      const versionId = event.currentTarget.dataset.id;
      await activatePromptVersion({ versionId });
      this.promptMessage = "Version activated. New runs will use it.";
      await this.refreshAfterVersionChange();
    } catch (e) {
      this.errorText = this.reduceError(e);
    }
  }

  async handlePublishVersion(event) {
    try {
      this.errorText = null;
      const versionId = event.currentTarget.dataset.id;
      await publishPromptVersion({ versionId });
      this.promptMessage = "Draft published and active.";
      await this.refreshAfterVersionChange();
    } catch (e) {
      this.errorText = this.reduceError(e);
    }
  }

  async handleRestoreVersion(event) {
    try {
      this.errorText = null;
      const versionId = event.currentTarget.dataset.id;
      const draftId = await restorePromptVersionAsDraft({ versionId });
      await this.refreshAfterVersionChange();
      // Restoring is only ever a means to editing the copy, so open it straight away.
      // Landing back on the list with a new draft and no obvious next step is what made
      // this action confusing before.
      this.openDraftForEditing(
        this.versions.find((v) => v.versionId === draftId)
      );
      this.promptMessage = "Copied into a new draft — edit and publish below.";
    } catch (e) {
      this.errorText = this.reduceError(e);
    }
  }

  handleDiffVersion(event) {
    const versionId = event.currentTarget.dataset.id;
    const version = this.versions.find((v) => v.versionId === versionId);
    if (!version) {
      return;
    }
    const active = this.versions.find((v) => v.isActive);
    const before = version.systemPrompt ?? "";
    const after = active?.systemPrompt ?? this.selected?.systemPrompt ?? "";
    const stats = diffStats(before, after);
    this.diff = {
      title: `v${version.versionNumber} → ${
        active ? `v${active.versionNumber} (active)` : "current"
      }`,
      summary: `+${stats.added} / −${stats.removed} lines`,
      unchanged: stats.added === 0 && stats.removed === 0,
      rows: diffRows(before, after)
    };
  }

  handleCloseDiff() {
    this.diff = null;
  }

  // Prompt edits change what getAgents returns (it overlays the active version), so both
  // the agent list and the version list have to come back.
  async refreshAfterVersionChange() {
    await this.loadAgents();
    await this.loadVersions();
  }

  // ── template helpers ────────────────────────────────────────

  get hasVersions() {
    return this.versions.length > 0;
  }

  get showPromptPanel() {
    return !this.editing && this.selected;
  }

  get savePromptDisabled() {
    return this.savingPrompt || !(this.promptDraft || "").trim();
  }

  get savePromptLabel() {
    if (this.editingVersionId) {
      return this.publishNow ? "Update & Publish" : "Update Draft";
    }
    return this.publishNow ? "Save & Publish" : "Save Draft";
  }

  get promptEditorTitle() {
    const version = this.editingVersionId
      ? this.versions.find((v) => v.versionId === this.editingVersionId)
      : null;
    return version
      ? `Editing draft ${version.versionLabel}`
      : "New version (from the active prompt)";
  }

  get activeVersionLabel() {
    const number = this.selected?.activePromptVersionNumber;
    return number ? `v${number}` : "Packaged baseline";
  }

  get accessLabel() {
    const permission = this.selected?.requiredCustomPermission;
    return permission ? `Requires ${permission}` : "Every framework user";
  }

  get hasTools() {
    return this.selected?.tools?.length > 0;
  }

  get showViewer() {
    return !this.editing && this.selected;
  }

  get devNameDisabled() {
    return !this.isNew;
  }

  get deployDisabled() {
    return (
      this.deploying ||
      !(this.form.developerName || "").trim() ||
      !(this.form.label || "").trim()
    );
  }

  reduceError(e) {
    return e?.body?.message || e?.message || "Something went wrong.";
  }
}
