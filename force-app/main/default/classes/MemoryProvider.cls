/**
 * @description The pluggable memory-store seam (mirrors `LLMClient`): implementations
 * recall relevant memories for a run and store newly captured ones. `SalesforceMemoryProvider`
 * is the SOQL-backed default; a vector-store provider slots in behind `MemoryProviderFactory`
 * without engine changes. Implementations must be callout-free unless invoked from a
 * `Database.AllowsCallouts` context.
 * @group Memory
 */
public interface MemoryProvider {
  /**
   * @description Returns the most relevant active memories for the query, best first.
   * @param query Who is asking and what about.
   * @return Ranked memories, at most `query.maxItems`.
   */
  List<MemoryRecord> recall(MemoryQuery query);

  /**
   * @description Persists newly captured memories.
   * @param records Memories to store.
   */
  void store(List<MemoryRecord> records);
}
