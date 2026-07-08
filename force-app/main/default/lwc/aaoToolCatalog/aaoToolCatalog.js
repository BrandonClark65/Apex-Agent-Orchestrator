import { LightningElement, track } from 'lwc';
import getToolCatalog from '@salesforce/apex/AgentBuilderController.getToolCatalog';

/**
 * Catalog of every registered tool: class, description, prompt guidance,
 * input/output schemas, and which agents are granted access.
 */
export default class AaoToolCatalog extends LightningElement {
    @track tools = [];
    errorText = null;

    async connectedCallback() {
        try {
            this.tools = (await getToolCatalog()).map((t) => ({
                ...t,
                expanded: false
            }));
        } catch (e) {
            this.errorText = e?.body?.message || e?.message;
        }
    }

    handleToggle(event) {
        const name = event.currentTarget.dataset.name;
        this.tools = this.tools.map((t) => {
            return t.developerName === name
                ? { ...t, expanded: !t.expanded }
                : t;
        });
    }
}
