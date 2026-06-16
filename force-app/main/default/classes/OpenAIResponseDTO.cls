public class OpenAIResponseDTO {
    public List<Choice> choices;
    public Usage usage;

    public class Choice {
        public Integer index;
        public Message message;
    }

    public class Message {
        public String role;
        public String content;
    }

    public class Usage {
        public Integer prompt_tokens;
        public Integer completion_tokens;
        public Integer total_tokens;
    }
}
