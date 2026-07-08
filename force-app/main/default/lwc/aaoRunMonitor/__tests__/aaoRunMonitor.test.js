import { createElement } from 'lwc';
import AaoRunMonitor from 'c/aaoRunMonitor';
import getRuns from '@salesforce/apex/AgentMonitorController.getRuns';

jest.mock(
    '@salesforce/apex/AgentMonitorController.getRuns',
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
jest.mock(
    'lightning/empApi',
    () => ({
        subscribe: jest.fn().mockResolvedValue({ id: 'sub' }),
        unsubscribe: jest.fn(),
        isEmpEnabled: jest.fn().mockResolvedValue(false)
    }),
    { virtual: true }
);

// eslint-disable-next-line @lwc/lwc/no-async-operation
const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('c-aao-run-monitor', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('loads runs into the datatable', async () => {
        getRuns.mockResolvedValue([
            {
                runId: 'a00xx0000000001',
                name: 'AR-0001',
                agentDeveloperName: 'CRUD_Agent',
                status: 'Succeeded',
                triggerType: 'Chat',
                depth: 0,
                startedAt: '2026-07-07T12:00:00.000Z'
            }
        ]);

        const el = createElement('c-aao-run-monitor', { is: AaoRunMonitor });
        document.body.appendChild(el);
        await flush();
        await flush();

        const table = el.shadowRoot.querySelector('lightning-datatable');
        expect(table.data).toHaveLength(1);
        expect(table.data[0].recordUrl).toBe('/a00xx0000000001');
        expect(getRuns).toHaveBeenCalledWith({
            statusFilter: null,
            agentFilter: null
        });
    });
});
