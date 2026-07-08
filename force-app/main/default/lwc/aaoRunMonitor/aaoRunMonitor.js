import { LightningElement, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { subscribe, unsubscribe, isEmpEnabled } from 'lightning/empApi';
import getRuns from '@salesforce/apex/AgentMonitorController.getRuns';
import cancelRun from '@salesforce/apex/AgentMonitorController.cancelRun';
import rerun from '@salesforce/apex/AgentMonitorController.rerun';

const UI_EVENT_CHANNEL = '/event/aao__Agent_UI_Event__e';

const STATUS_OPTIONS = [
    { label: 'All statuses', value: '' },
    { label: 'Running', value: 'Running' },
    { label: 'Succeeded', value: 'Succeeded' },
    { label: 'Failed', value: 'Failed' },
    { label: 'Cancelled', value: 'Cancelled' }
];

const COLUMNS = [
    {
        label: 'Run',
        fieldName: 'recordUrl',
        type: 'url',
        typeAttributes: { label: { fieldName: 'name' } },
        initialWidth: 110
    },
    { label: 'Agent', fieldName: 'agentDeveloperName' },
    { label: 'Status', fieldName: 'status', initialWidth: 110 },
    { label: 'Trigger', fieldName: 'triggerType', initialWidth: 100 },
    { label: 'Depth', fieldName: 'depth', type: 'number', initialWidth: 80 },
    {
        label: 'Started',
        fieldName: 'startedAt',
        type: 'date',
        typeAttributes: {
            month: 'short',
            day: 'numeric',
            hour: '2-digit',
            minute: '2-digit'
        }
    },
    {
        type: 'action',
        typeAttributes: {
            rowActions: [
                { label: 'Cancel', name: 'cancel' },
                { label: 'Re-run', name: 'rerun' }
            ]
        }
    }
];

/**
 * Live run-monitoring table: filterable by status/agent, refreshes on
 * Agent_UI_Event__e (with a manual Refresh button as fallback), row actions
 * for Cancel and Re-run.
 */
export default class AaoRunMonitor extends NavigationMixin(LightningElement) {
    columns = COLUMNS;
    statusOptions = STATUS_OPTIONS;
    @track rows = [];
    statusFilter = '';
    agentFilter = '';
    errorText = null;

    _subscription = null;

    async connectedCallback() {
        await this.refresh();
        const enabled = await isEmpEnabled();
        if (enabled) {
            this._subscription = await subscribe(UI_EVENT_CHANNEL, -1, () =>
                this.refresh()
            );
        }
    }

    disconnectedCallback() {
        if (this._subscription) {
            unsubscribe(this._subscription);
            this._subscription = null;
        }
    }

    async refresh() {
        try {
            this.errorText = null;
            const runs = await getRuns({
                statusFilter: this.statusFilter || null,
                agentFilter: this.agentFilter || null
            });
            this.rows = runs.map((r) => ({
                ...r,
                recordUrl: `/${r.runId}`
            }));
        } catch (e) {
            this.errorText = this.reduceError(e);
        }
    }

    handleStatusFilter(event) {
        this.statusFilter = event.detail.value;
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

    handleRefresh() {
        this.refresh();
    }

    async handleRowAction(event) {
        const action = event.detail.action.name;
        const row = event.detail.row;
        this.errorText = null;
        try {
            if (action === 'cancel') {
                await cancelRun({ runId: row.runId });
            } else if (action === 'rerun') {
                const newRunId = await rerun({ runId: row.runId });
                this[NavigationMixin.Navigate]({
                    type: 'standard__recordPage',
                    attributes: {
                        recordId: newRunId,
                        actionName: 'view'
                    }
                });
            }
            await this.refresh();
        } catch (e) {
            this.errorText = this.reduceError(e);
        }
    }

    reduceError(e) {
        return e?.body?.message || e?.message || 'Something went wrong.';
    }
}
