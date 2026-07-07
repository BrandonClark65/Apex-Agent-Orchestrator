import { LightningElement, api, track } from 'lwc';
import { subscribe, unsubscribe, isEmpEnabled } from 'lightning/empApi';
import getAvailableAgents from '@salesforce/apex/AgentChatController.getAvailableAgents';
import sendMessage from '@salesforce/apex/AgentChatController.sendMessage';
import getSessionState from '@salesforce/apex/AgentChatController.getSessionState';
import getMySessions from '@salesforce/apex/AgentChatController.getMySessions';

const UI_EVENT_CHANNEL = '/event/aao__Agent_UI_Event__e';
const POLL_INTERVAL_MS = 4000;

/**
 * Chat container: session sidebar, agent picker, message thread, composer, and a
 * thinking indicator. Live progress arrives over empApi (Agent_UI_Event__e); a
 * polling timer covers orgs where streaming is unavailable.
 */
export default class AaoAgentChat extends LightningElement {
    /** Pin the chat to one agent (design-time property on App/Record pages). */
    @api agentDeveloperName;
    /** Record page context; attached to the first message when present. */
    @api recordId;

    @track sessions = [];
    @track messages = [];
    agents = [];
    selectedAgent;
    sessionId;
    sessionStatus = 'Active';
    inputText = '';
    thinkingText = null;
    errorText = null;

    _subscription = null;
    _pollTimer = null;

    async connectedCallback() {
        try {
            this.agents = await getAvailableAgents();
            if (this.agentDeveloperName) {
                this.selectedAgent = this.agentDeveloperName;
            } else if (this.agents.length) {
                this.selectedAgent = this.agents[0].developerName;
            }
            await this.refreshSessions();
            await this.subscribeToUiEvents();
        } catch (e) {
            this.errorText = this.reduceError(e);
        }
    }

    disconnectedCallback() {
        if (this._subscription) {
            unsubscribe(this._subscription);
            this._subscription = null;
        }
        this.stopPolling();
    }

    // ── live updates ────────────────────────────────────────────

    async subscribeToUiEvents() {
        const enabled = await isEmpEnabled();
        if (!enabled) {
            return; // polling fallback covers it
        }
        this._subscription = await subscribe(UI_EVENT_CHANNEL, -1, (event) =>
            this.handleUiEvent(event)
        );
    }

    handleUiEvent(event) {
        const payload = event?.data?.payload ?? {};
        const sessionId =
            payload.aao__Session_Id__c ?? payload.Session_Id__c ?? null;
        if (!this.sessionId || sessionId !== this.sessionId) {
            return;
        }
        const eventType =
            payload.aao__Event_Type__c ?? payload.Event_Type__c ?? '';
        const detail = this.parseJson(
            payload.aao__Payload_Json__c ?? payload.Payload_Json__c
        );

        if (eventType === 'StepCompleted') {
            this.thinkingText = detail?.toolName
                ? `Calling ${detail.toolName}…`
                : 'Thinking…';
        } else if (eventType === 'RunFinished') {
            this.finishTurn();
        }
    }

    startPolling() {
        this.stopPolling();
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._pollTimer = setInterval(async () => {
            try {
                const state = await getSessionState({
                    sessionId: this.sessionId
                });
                if (state.status !== 'Busy') {
                    this.finishTurn();
                }
            } catch {
                // keep polling; transient errors are fine
            }
        }, POLL_INTERVAL_MS);
    }

    stopPolling() {
        if (this._pollTimer) {
            clearInterval(this._pollTimer);
            this._pollTimer = null;
        }
    }

    async finishTurn() {
        this.stopPolling();
        this.thinkingText = null;
        await this.loadSession(this.sessionId);
        await this.refreshSessions();
    }

    // ── data loads ──────────────────────────────────────────────

    async refreshSessions() {
        this.sessions = (
            await getMySessions({
                agentDeveloperName: this.agentDeveloperName ?? null
            })
        ).map((s) => ({
            ...s,
            cssClass:
                s.sessionId === this.sessionId
                    ? 'session-item selected'
                    : 'session-item'
        }));
    }

    async loadSession(sessionId) {
        const state = await getSessionState({ sessionId });
        this.sessionId = state.sessionId;
        this.sessionStatus = state.status;
        this.messages = this.withKeys(state.messages);
        if (state.latestRunStatus === 'Failed') {
            this.errorText = state.latestRunError || 'The last run failed.';
        }
    }

    // ── user actions ────────────────────────────────────────────

    handleAgentChange(event) {
        this.selectedAgent = event.detail.value;
    }

    handleInputChange(event) {
        this.inputText = event.target.value;
    }

    handleKeyDown(event) {
        if (event.key === 'Enter' && !event.shiftKey) {
            event.preventDefault();
            this.handleSend();
        }
    }

    async handleSend() {
        const text = (this.inputText || '').trim();
        if (!text || this.isBusy) {
            return;
        }
        this.errorText = null;
        this.inputText = '';
        // optimistic user bubble
        this.messages = this.withKeys([
            ...this.messages,
            { role: 'user', text }
        ]);
        this.sessionStatus = 'Busy';
        this.thinkingText = 'Thinking…';

        const message = this.recordId
            ? `${text}\n\n(Context: this conversation is about record ${this.recordId})`
            : text;

        try {
            const turn = await sendMessage({
                agentDeveloperName: this.selectedAgent,
                sessionId: this.sessionId ?? null,
                message
            });
            this.sessionId = turn.sessionId;
            this.startPolling();
            this.refreshSessions();
        } catch (e) {
            this.sessionStatus = 'Active';
            this.thinkingText = null;
            this.errorText = this.reduceError(e);
        }
    }

    async handleSessionClick(event) {
        const sessionId = event.currentTarget.dataset.id;
        this.stopPolling();
        this.thinkingText = null;
        this.errorText = null;
        await this.loadSession(sessionId);
        if (this.sessionStatus === 'Busy') {
            this.thinkingText = 'Working…';
            this.startPolling();
        }
        await this.refreshSessions();
    }

    handleNewChat() {
        this.stopPolling();
        this.sessionId = null;
        this.sessionStatus = 'Active';
        this.messages = [];
        this.thinkingText = null;
        this.errorText = null;
        this.refreshSessions();
    }

    // ── template helpers ────────────────────────────────────────

    get agentOptions() {
        return this.agents.map((a) => ({
            label: a.label,
            value: a.developerName
        }));
    }

    get showAgentPicker() {
        return !this.agentDeveloperName && !this.sessionId;
    }

    get isBusy() {
        return this.sessionStatus === 'Busy';
    }

    get composerDisabled() {
        return this.isBusy || this.sessionStatus === 'Closed';
    }

    get sendDisabled() {
        return this.composerDisabled || !(this.inputText || '').trim();
    }

    get hasMessages() {
        return this.messages.length > 0;
    }

    // ── utils ───────────────────────────────────────────────────

    withKeys(messages) {
        return (messages || []).map((m, i) => ({ ...m, key: `msg-${i}` }));
    }

    parseJson(text) {
        try {
            return text ? JSON.parse(text) : null;
        } catch {
            return null;
        }
    }

    reduceError(e) {
        return (
            e?.body?.message ||
            e?.message ||
            'Something went wrong. Please try again.'
        );
    }
}
