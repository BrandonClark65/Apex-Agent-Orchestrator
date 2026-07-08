import { LightningElement, track } from 'lwc';
import getAgents from '@salesforce/apex/AgentBuilderController.getAgents';
import getTestCases from '@salesforce/apex/AgentBuilderController.getTestCases';
import saveTestCase from '@salesforce/apex/AgentBuilderController.saveTestCase';
import testRun from '@salesforce/apex/AgentBuilderController.testRun';

/**
 * Test bench: pick an agent, edit an input JSON (or load a saved sample), run it for
 * real, and watch the live step trace via the embedded run-detail component. Saved
 * samples live in Test_Case__c records.
 */
export default class AaoTestBench extends LightningElement {
    agents = [];
    @track testCases = [];
    selectedAgent = null;
    selectedCaseId = null;
    inputJson = '{"task": ""}';
    caseName = '';
    runId = null;
    errorText = null;

    async connectedCallback() {
        try {
            this.agents = await getAgents();
            if (this.agents.length) {
                this.selectedAgent = this.agents[0].developerName;
                await this.loadCases();
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

    get runDisabled() {
        return !this.selectedAgent || !(this.inputJson || '').trim();
    }

    get saveDisabled() {
        return this.runDisabled || !(this.caseName || '').trim();
    }

    async handleAgentChange(event) {
        this.selectedAgent = event.detail.value;
        this.runId = null;
        await this.loadCases();
    }

    handleCaseChange(event) {
        this.selectedCaseId = event.detail.value;
        const tc = this.testCases.find(
            (c) => c.testCaseId === this.selectedCaseId
        );
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
            this.caseName = '';
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
            this.errorText = 'Input is not valid JSON: ' + e.message;
            return;
        }
        try {
            this.runId = null;
            this.runId = await testRun({
                agentDeveloperName: this.selectedAgent,
                inputJson: this.inputJson
            });
        } catch (e) {
            this.errorText = this.reduceError(e);
        }
    }

    reduceError(e) {
        return e?.body?.message || e?.message || 'Something went wrong.';
    }
}
