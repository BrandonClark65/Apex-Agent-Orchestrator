import { LightningElement, track } from 'lwc';
import canManageAll from '@salesforce/apex/MemoryManagerController.canManageAll';
import getMyMemories from '@salesforce/apex/MemoryManagerController.getMyMemories';
import getAllMemories from '@salesforce/apex/MemoryManagerController.getAllMemories';
import setActive from '@salesforce/apex/MemoryManagerController.setActive';
import deleteMemory from '@salesforce/apex/MemoryManagerController.deleteMemory';

const TYPE_OPTIONS = [
    { label: 'All types', value: '' },
    { label: 'Fact', value: 'Fact' },
    { label: 'Preference', value: 'Preference' },
    { label: 'Reflection', value: 'Reflection' },
    { label: 'Summary', value: 'Summary' }
];

/**
 * Memory management: "what agents remember about me" for every user, plus an
 * admin view over all memories (including the Reflection review queue).
 * Deactivate = soft delete (memory stops being recalled but stays auditable);
 * Delete = permanent.
 */
export default class AaoMemoryManager extends LightningElement {
    typeOptions = TYPE_OPTIONS;
    @track rows = [];
    isAdmin = false;
    view = 'mine'; // 'mine' | 'all'
    agentFilter = '';
    typeFilter = '';
    includeInactive = false;
    errorText = null;

    async connectedCallback() {
        try {
            this.isAdmin = await canManageAll();
        } catch {
            this.isAdmin = false;
        }
        await this.refresh();
    }

    async refresh() {
        try {
            this.errorText = null;
            const raw =
                this.view === 'all'
                    ? await getAllMemories({
                          agentFilter: this.agentFilter || null,
                          typeFilter: this.typeFilter || null,
                          includeInactive: this.includeInactive
                      })
                    : await getMyMemories({
                          includeInactive: this.includeInactive
                      });
            this.rows = raw.map((m) => ({
                ...m,
                statusLabel: m.isActive ? 'Active' : 'Inactive',
                statusClass: m.isActive
                    ? 'slds-badge slds-theme_success'
                    : 'slds-badge',
                toggleLabel: m.isActive ? 'Deactivate' : 'Activate'
            }));
        } catch (e) {
            this.errorText = this.reduceError(e);
        }
    }

    get isMine() {
        return this.view === 'mine';
    }

    get isAll() {
        return this.view === 'all';
    }

    get mineVariant() {
        return this.isMine ? 'brand' : 'neutral';
    }

    get allVariant() {
        return this.isAll ? 'brand' : 'neutral';
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    handleShowMine() {
        this.view = 'mine';
        this.refresh();
    }

    handleShowAll() {
        this.view = 'all';
        this.refresh();
    }

    handleAgentFilter(event) {
        this.agentFilter = event.target.value;
    }

    handleAgentFilterCommit(event) {
        if (event.key === 'Enter') {
            this.refresh();
        }
    }

    handleTypeFilter(event) {
        this.typeFilter = event.detail.value;
        this.refresh();
    }

    handleIncludeInactive(event) {
        this.includeInactive = event.target.checked;
        this.refresh();
    }

    async handleToggleActive(event) {
        const { id, active } = event.currentTarget.dataset;
        try {
            await setActive({ memoryId: id, isActive: active !== 'true' });
            await this.refresh();
        } catch (e) {
            this.errorText = this.reduceError(e);
        }
    }

    async handleDelete(event) {
        const id = event.currentTarget.dataset.id;
        try {
            await deleteMemory({ memoryId: id });
            await this.refresh();
        } catch (e) {
            this.errorText = this.reduceError(e);
        }
    }

    reduceError(e) {
        return e?.body?.message || e?.message || 'Something went wrong.';
    }
}
