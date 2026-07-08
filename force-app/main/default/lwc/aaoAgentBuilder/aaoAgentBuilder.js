import { LightningElement, track } from 'lwc';
import getAgents from '@salesforce/apex/AgentBuilderController.getAgents';
import getManifestPreview from '@salesforce/apex/AgentBuilderController.getManifestPreview';

/**
 * Read-only agent configuration viewer: agent list, definition detail (prompt, goal,
 * provider, memory config, granted tools with schemas), and a "what the LLM actually
 * sees" tool-manifest preview. Agents are Custom Metadata, so authoring happens in
 * Setup/deploys — this surface is for understanding and iterating.
 */
export default class AaoAgentBuilder extends LightningElement {
    @track agents = [];
    selected = null;
    manifest = null;
    errorText = null;

    async connectedCallback() {
        try {
            this.agents = (await getAgents()).map((a) => ({
                ...a,
                cssClass: 'agent-item',
                statusLabel: a.isActive ? 'Active' : 'Inactive',
                badgeClass: a.isActive
                    ? 'slds-badge slds-theme_success'
                    : 'slds-badge'
            }));
            if (this.agents.length) {
                this.select(this.agents[0].developerName);
            }
        } catch (e) {
            this.errorText = e?.body?.message || e?.message;
        }
    }

    handleSelect(event) {
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
            this.errorText = e?.body?.message || e?.message;
        }
    }

    get hasTools() {
        return this.selected?.tools?.length > 0;
    }
}
