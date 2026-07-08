import { createElement } from 'lwc';
import AaoRunDetail from 'c/aaoRunDetail';
import getRunDetail from '@salesforce/apex/AgentMonitorController.getRunDetail';
import getRunTree from '@salesforce/apex/AgentMonitorController.getRunTree';

jest.mock(
    '@salesforce/apex/AgentMonitorController.getRunDetail',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/AgentMonitorController.getStepDetail',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/AgentMonitorController.getRunTree',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/AgentMonitorController.cancelRun',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/AgentMonitorController.rerun',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

// eslint-disable-next-line @lwc/lwc/no-async-operation
const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('c-aao-run-detail', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('renders the step timeline with pending sub-agent flag', async () => {
        getRunDetail.mockResolvedValue({
            summary: {
                runId: 'a00xx0000000001',
                status: 'Running',
                agentDeveloperName: 'Orchestrator_Agent'
            },
            steps: [
                {
                    stepId: 's1',
                    stepNumber: 1,
                    stepType: 'LLMCall',
                    status: 'Completed'
                },
                {
                    stepId: 's2',
                    stepNumber: 2,
                    stepType: 'ToolCall',
                    status: 'Pending',
                    toolName: 'SubAgentTool'
                }
            ]
        });
        getRunTree.mockResolvedValue([
            {
                runId: 'a00xx0000000001',
                name: 'AR-0001',
                agentDeveloperName: 'Orchestrator_Agent',
                status: 'Running',
                depth: 0
            },
            {
                runId: 'a00xx0000000002',
                name: 'AR-0002',
                agentDeveloperName: 'CRUD_Agent',
                status: 'Running',
                depth: 1,
                parentRunId: 'a00xx0000000001'
            }
        ]);

        const el = createElement('c-aao-run-detail', { is: AaoRunDetail });
        el.recordId = 'a00xx0000000001';
        document.body.appendChild(el);
        await flush();
        await flush();

        const text = el.shadowRoot.textContent;
        expect(text).toContain('1. LLMCall');
        expect(text).toContain('2. ToolCall — SubAgentTool');
        expect(text).toContain('waiting on sub-agent');
        expect(text).toContain('Run Family');
        expect(text).toContain('AR-0002');
        // Cancel offered for a Running run
        const cancel = Array.from(
            el.shadowRoot.querySelectorAll('lightning-button')
        ).find((b) => b.label === 'Cancel Run');
        expect(cancel).not.toBeUndefined();
    });
});
