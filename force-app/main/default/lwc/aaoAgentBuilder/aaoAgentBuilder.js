import { LightningElement, track } from 'lwc';
import { subscribe, unsubscribe, isEmpEnabled } from 'lightning/empApi';
import getAgents from '@salesforce/apex/AgentBuilderController.getAgents';
import getManifestPreview from '@salesforce/apex/AgentBuilderController.getManifestPreview';
import getToolCatalog from '@salesforce/apex/AgentBuilderController.getToolCatalog';
import getProviderOptions from '@salesforce/apex/AgentBuilderController.getProviderOptions';
import getMemoryConfigOptions from '@salesforce/apex/AgentBuilderController.getMemoryConfigOptions';
import saveAgent from '@salesforce/apex/AgentBuilderController.saveAgent';

const UI_EVENT_CHANNEL = '/event/aao__Agent_UI_Event__e';
const DEPLOY_TIMEOUT_MS = 90000;

/**
 * Agent configuration viewer and editor. Viewing is read from CMDT; editing deploys
 * changes through the Metadata API (AgentDeployService) — the Deploy button submits a
 * real metadata deployment, and completion arrives on Agent_UI_Event__e as a
 * DeployFinished event keyed by the deployment job id.
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
                this._subscription = await subscribe(
                    UI_EVENT_CHANNEL,
                    -1,
                    (event) => this.handleUiEvent(event)
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
            cssClass: 'agent-item',
            statusLabel: a.isActive ? 'Active' : 'Inactive',
            badgeClass: a.isActive
                ? 'slds-badge slds-theme_success'
                : 'slds-badge'
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
                a.developerName === developerName
                    ? 'agent-item selected'
                    : 'agent-item'
        }));
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
                developerName: source?.developerName ?? '',
                label: source?.label ?? '',
                goal: source?.goal ?? '',
                systemPrompt: source?.systemPrompt ?? '',
                llmProvider:
                    source?.llmProvider ?? this.providerOptions[0]?.value,
                maxSteps: source?.maxSteps ?? 10,
                memoryConfig:
                    source?.memoryConfig ?? this.memoryOptions[0]?.value,
                isActive: source ? source.isActive : true
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
            event.target.type === 'checkbox'
                ? event.target.checked
                : event.detail?.value ?? event.target.value;
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
            this.deployMessage = 'Submitting metadata deployment…';

            const request = {
                ...this.form,
                maxSteps: parseInt(this.form.maxSteps, 10) || 10,
                tools: this.toolRows.map((t) => ({
                    toolDeveloperName: t.developerName,
                    allowed: t.allowed
                }))
            };
            this.deployJobId = await saveAgent({
                requestJson: JSON.stringify(request)
            });
            this.deployMessage = 'Deploying… (this usually takes a few seconds)';

            // Fallback if the completion event never arrives (empApi off, etc.)
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            this._deployTimer = setTimeout(() => {
                if (this.deploying) {
                    this.finishDeploy(
                        true,
                        'Deployment submitted. Refresh to see the result.'
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
        const eventType =
            payload.aao__Event_Type__c ?? payload.Event_Type__c ?? '';
        if (eventType !== 'DeployFinished' || !this.deploying) {
            return;
        }
        const runId = payload.aao__Run_Id__c ?? payload.Run_Id__c ?? '';
        if (this.deployJobId && !this.deployJobId.startsWith(runId)) {
            return;
        }
        let detail = {};
        try {
            detail = JSON.parse(
                payload.aao__Payload_Json__c ?? payload.Payload_Json__c ?? '{}'
            );
        } catch {
            detail = {};
        }
        if (detail.succeeded) {
            this.finishDeploy(true, 'Deployed successfully.');
        } else {
            this.finishDeploy(
                false,
                'Deployment failed: ' +
                    (detail.errors?.join('; ') || 'unknown error')
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

    // ── template helpers ────────────────────────────────────────

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
            !(this.form.developerName || '').trim() ||
            !(this.form.label || '').trim()
        );
    }

    reduceError(e) {
        return e?.body?.message || e?.message || 'Something went wrong.';
    }
}
