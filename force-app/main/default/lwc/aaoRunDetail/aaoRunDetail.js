import { LightningElement, api, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getRunDetail from '@salesforce/apex/AgentMonitorController.getRunDetail';
import getStepDetail from '@salesforce/apex/AgentMonitorController.getStepDetail';
import getRunTree from '@salesforce/apex/AgentMonitorController.getRunTree';
import cancelRun from '@salesforce/apex/AgentMonitorController.cancelRun';
import rerun from '@salesforce/apex/AgentMonitorController.rerun';

const STEP_ICONS = {
    Plan: 'utility:list',
    LLMCall: 'utility:einstein',
    ToolCall: 'utility:apex',
    InvalidTool: 'utility:warning',
    ToolResult: 'utility:reply',
    Reflection: 'utility:thunder',
    Summary: 'utility:summary'
};

/**
 * Run detail for the Agent_Run__c record page: header status, vertical step
 * timeline (expandable to full request/response text), and the sub-agent
 * family tree with links.
 */
export default class AaoRunDetail extends NavigationMixin(LightningElement) {
    @api recordId;

    @track detail = null;
    @track steps = [];
    @track family = [];
    errorText = null;

    async connectedCallback() {
        await this.refresh();
    }

    async refresh() {
        try {
            this.errorText = null;
            const detail = await getRunDetail({ runId: this.recordId });
            this.detail = detail;
            this.steps = detail.steps.map((s) => ({
                ...s,
                icon: STEP_ICONS[s.stepType] || 'utility:record',
                title: `${s.stepNumber}. ${s.stepType}${s.toolName ? ' — ' + s.toolName : ''}`,
                statusClass: this.statusClass(s.status),
                isPending: s.status === 'Pending',
                expanded: false,
                fullDetail: null
            }));

            const family = await getRunTree({ runId: this.recordId });
            this.family = family.map((r) => ({
                ...r,
                indentStyle: `padding-left: ${r.depth * 1.5}rem`,
                isCurrent: r.runId === this.recordId,
                recordUrl: `/${r.runId}`
            }));
        } catch (e) {
            this.errorText = this.reduceError(e);
        }
    }

    get statusBadgeClass() {
        return this.statusClass(this.detail?.summary?.status);
    }

    get canCancel() {
        return this.detail?.summary?.status === 'Running';
    }

    get showFamily() {
        return this.family.length > 1;
    }

    statusClass(status) {
        switch (status) {
            case 'Succeeded':
            case 'Completed':
                return 'slds-badge slds-theme_success';
            case 'Failed':
                return 'slds-badge slds-theme_error';
            case 'Running':
            case 'InProgress':
            case 'Pending':
                return 'slds-badge slds-theme_warning';
            default:
                return 'slds-badge';
        }
    }

    async handleToggleStep(event) {
        const stepId = event.currentTarget.dataset.id;
        const step = this.steps.find((s) => s.stepId === stepId);
        if (!step) {
            return;
        }
        step.expanded = !step.expanded;
        if (step.expanded && !step.fullDetail) {
            try {
                step.fullDetail = await getStepDetail({ stepId });
            } catch (e) {
                this.errorText = this.reduceError(e);
            }
        }
        this.steps = [...this.steps];
    }

    async handleCancel() {
        try {
            await cancelRun({ runId: this.recordId });
            await this.refresh();
        } catch (e) {
            this.errorText = this.reduceError(e);
        }
    }

    async handleRerun() {
        try {
            const newRunId = await rerun({ runId: this.recordId });
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId: newRunId, actionName: 'view' }
            });
        } catch (e) {
            this.errorText = this.reduceError(e);
        }
    }

    handleRefresh() {
        this.refresh();
    }

    reduceError(e) {
        return e?.body?.message || e?.message || 'Something went wrong.';
    }
}
