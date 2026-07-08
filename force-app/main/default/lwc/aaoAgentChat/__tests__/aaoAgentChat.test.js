import { createElement } from 'lwc';
import AaoAgentChat from 'c/aaoAgentChat';
import getAvailableAgents from '@salesforce/apex/AgentChatController.getAvailableAgents';
import sendMessage from '@salesforce/apex/AgentChatController.sendMessage';
import getMySessions from '@salesforce/apex/AgentChatController.getMySessions';
import getSessionState from '@salesforce/apex/AgentChatController.getSessionState';

jest.mock(
    '@salesforce/apex/AgentChatController.getAvailableAgents',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/AgentChatController.sendMessage',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/AgentChatController.getMySessions',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/AgentChatController.getSessionState',
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

function mount() {
    const el = createElement('c-aao-agent-chat', { is: AaoAgentChat });
    document.body.appendChild(el);
    return el;
}

describe('c-aao-agent-chat', () => {
    beforeEach(() => {
        getAvailableAgents.mockResolvedValue([
            { developerName: 'CRUD_Agent', label: 'CRUD Agent', goal: 'CRUD' }
        ]);
        getMySessions.mockResolvedValue([]);
        sendMessage.mockResolvedValue({
            sessionId: 'a01xx0000000001',
            runId: 'a00xx0000000001'
        });
        getSessionState.mockResolvedValue({
            sessionId: 'a01xx0000000001',
            status: 'Active',
            messages: []
        });
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('loads agents and shows the picker', async () => {
        const el = mount();
        await flush();
        await flush();
        const combobox = el.shadowRoot.querySelector('lightning-combobox');
        expect(combobox).not.toBeNull();
        expect(getAvailableAgents).toHaveBeenCalled();
    });

    it('disables Send while the input is empty', async () => {
        const el = mount();
        await flush();
        await flush();

        const sendButton = Array.from(
            el.shadowRoot.querySelectorAll('lightning-button')
        ).find((b) => b.label === 'Send');
        expect(sendButton).not.toBeUndefined();
        expect(sendButton.disabled).toBe(true);
    });

    it('calls sendMessage with the chosen agent', async () => {
        const el = mount();
        await flush();
        await flush();

        // reach in via composer events: simulate typed text then Enter key
        const textarea = el.shadowRoot.querySelector('lightning-textarea');
        Object.defineProperty(textarea, 'value', {
            value: 'Hello agent',
            writable: true
        });
        textarea.dispatchEvent(new CustomEvent('change'));
        await flush();

        textarea.dispatchEvent(
            new KeyboardEvent('keydown', { key: 'Enter', shiftKey: false })
        );
        await flush();

        expect(sendMessage).toHaveBeenCalledWith(
            expect.objectContaining({
                agentDeveloperName: 'CRUD_Agent',
                sessionId: null,
                message: 'Hello agent'
            })
        );
    });
});
