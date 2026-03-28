# Chapter 24: Vector Search and AI Applications

If there's a single theme defining modern application development right now, it's AI. Large language models, embedding-based retrieval, autonomous agents—these aren't far-off experiments anymore. They're the features your users expect. And here's the thing: every one of those AI capabilities needs a database behind it. Not just *any* database, but one that can store your operational data, your vector embeddings, your conversation histories, and your agent state—all in one place, with the performance and scale guarantees you'd expect from a globally distributed service.

That's exactly where Azure Cosmos DB steps in. Over the last few chapters, you've mastered queries, indexing, data modeling, and change feed. Now it's time to put all of that together in the context of AI. In this chapter, you'll learn how to turn Cosmos DB into the backbone of your AI applications—from vector search fundamentals to building full-blown RAG systems, managing AI agent memories, and integrating with every major AI framework on the market.

## Cosmos DB as a Unified AI Database

Traditionally, building an AI-powered application meant stitching together multiple databases: an operational store for your transactional data, a separate vector database for embeddings, maybe a cache layer for conversation history, and yet another store for agent state. That architecture is fragile, expensive, and operationally painful.

Cosmos DB eliminates that sprawl. Because it's a schema-flexible document database with first-class vector search, you can store your documents *and* their embedding vectors in the same items. Your product catalog entry can sit alongside its 1536-dimensional embedding. Your support ticket can carry both its text content and a vector representation—all in a single JSON document, within a single container, managed by a single service.

This colocation matters. It means no synchronization pipelines between your "real" database and your vector store. No stale embeddings. No extra network hops. When you update a document, its vector is right there with it. When you query, you can combine vector similarity with traditional filters in a single operation. And because it's Cosmos DB, you get global distribution, guaranteed SLAs, and automatic scaling across all of that data.

## What Is Vector Search?

Before we dive into configuration, let's make sure the fundamentals are solid.

### Embeddings

An *embedding* is a numerical representation of data—text, images, audio, or anything else—in a high-dimensional space. When you pass a sentence through an embedding model like OpenAI's `text-embedding-3-small`, you get back an array of floating-point numbers (say, 1536 of them). Each dimension captures some aspect of the meaning. Similar concepts end up as vectors that are close together in this space; dissimilar concepts are far apart.

### Similarity and Distance Functions

To find "similar" items, you measure the distance between vectors. Cosmos DB supports three distance functions:

- **Cosine similarity**: Measures the angle between two vectors. Values range from −1 (opposite) to +1 (identical direction). This is the most common choice for text embeddings.
- **Dot product**: Measures the projection of one vector onto another. Values range from −∞ to +∞. Works well when vectors are normalized.
- **Euclidean distance**: Measures the straight-line distance between two points in the vector space. Values range from 0 (identical) to +∞. Good for spatial data.

### The RAG Pattern

Retrieval-Augmented Generation (RAG) is the dominant pattern for grounding LLM responses in your own data. The flow goes like this:

1. A user asks a question.
2. You convert that question into a vector embedding.
3. You search your database for documents whose embeddings are most similar to the question vector.
4. You pass those documents as context to the LLM along with the original question.
5. The LLM generates a response grounded in your actual data—not its training data alone.

Cosmos DB is a natural fit for step 3, because it can serve as both your operational store *and* your vector store.

## Configuring Vector Embeddings on a Container

To use vector search, you need to configure two things when you create a container: a **vector embedding policy** and a **vector index** in the indexing policy.

> **Important:** Vector embedding policies and vector indexes cannot be modified in place. To change settings, you must drop the existing vector policy and index, then re-add them with new configuration.

### The Vector Embedding Policy

The vector embedding policy tells Cosmos DB which properties contain vectors and how to handle them. Each entry specifies:

| Parameter | Description | Default |
|---|---|---|
| `path` | The JSON property path containing the vector | (required) |
| `dataType` | Element type: `float32`, `float16`, `int8`, or `uint8` | `float32` |
| `dimensions` | Number of dimensions in the vector | `1536` |
| `distanceFunction` | How to measure similarity: `cosine`, `dotproduct`, or `euclidean` | `cosine` |

Here's a complete container definition with a vector embedding policy, a vector index, and the standard indexing policy:

```json
{
  "vectorEmbeddingPolicy": {
    "vectorEmbeddings": [
      {
        "path": "/contentVector",
        "dataType": "float32",
        "distanceFunction": "cosine",
        "dimensions": 1536
      }
    ]
  },
  "indexingPolicy": {
    "indexingMode": "consistent",
    "automatic": true,
    "includedPaths": [
      { "path": "/*" }
    ],
    "excludedPaths": [
      { "path": "/_etag/?" },
      { "path": "/contentVector/*" }
    ],
    "vectorIndexes": [
      {
        "path": "/contentVector",
        "type": "diskANN"
      }
    ]
  }
}
```

Notice that `/contentVector/*` is in the `excludedPaths`. This is critical—if you don't exclude the vector path from the regular index, you'll pay significantly higher RU costs and latency on every insert. The vector index itself handles the vector data; the regular index doesn't need it.

You can define multiple vector paths if your documents carry more than one embedding (say, one for the title and one for the full content):

```json
{
  "vectorEmbeddings": [
    {
      "path": "/titleVector",
      "dataType": "float32",
      "distanceFunction": "cosine",
      "dimensions": 1536
    },
    {
      "path": "/contentVector",
      "dataType": "int8",
      "distanceFunction": "dotproduct",
      "dimensions": 256
    }
  ]
}
```

The `int8` and `uint8` data types are useful when you have quantized embeddings—they use less storage and can improve throughput, though at some cost to precision.

## Vector Indexing with DiskANN

Not all vector indexes are equal. Cosmos DB gives you three options, and choosing the right one matters enormously for performance:

### Flat Index

The `flat` index stores vectors alongside other indexed properties. Searches are brute-force (exact k-nearest neighbors), so you get 100% recall—but at the cost of scanning every vector. It's limited to 505 dimensions and best suited for very small datasets or when combined with tight `WHERE` clause filters that drastically narrow the search space.

### Quantized Flat Index

The `quantizedFlat` index compresses vectors using quantization before storing them. It's still a brute-force search, but over compressed data—so it's faster and cheaper than `flat` while sacrificing minimal accuracy. Good for up to roughly 50,000 vectors per physical partition. Supports up to 4,096 dimensions.

### DiskANN Index

`diskANN` is the powerhouse. Built on Microsoft Research's [DiskANN algorithms](https://www.microsoft.com/research/publication/diskann-fast-accurate-billion-point-nearest-neighbor-search-on-a-single-node/), it's an approximate nearest-neighbor (ANN) index optimized for high throughput, low latency, and cost efficiency at massive scale. When you have more than 50,000 vectors per physical partition—which is most production scenarios—DiskANN is the clear winner.

Both `quantizedFlat` and `diskANN` require at least 1,000 vectors before the index becomes effective. Below that threshold, the engine falls back to a full scan.

You can tune DiskANN's accuracy-vs-performance trade-off with optional parameters:

- **`quantizationByteSize`** (1–512): Controls compression level. Larger values improve accuracy at the cost of higher RU consumption.
- **`indexingSearchListSize`** (10–500, default 100): Controls how many vectors are considered during index construction. Larger values yield better recall but slower index builds.

### Sharded DiskANN for Multi-Tenant Scenarios

In multi-tenant applications, you often want to search within a single tenant's data. Sharded DiskANN lets you partition the DiskANN index by a property (like `tenantId`), creating separate mini-indexes per shard:

```json
{
  "vectorIndexes": [
    {
      "path": "/contentVector",
      "type": "diskANN",
      "vectorIndexShardKey": ["/tenantId"]
    }
  ]
}
```

Then, when you query with a `WHERE c.tenantId = "tenant-abc"` filter, Cosmos DB searches only that tenant's shard—resulting in lower latency, lower cost, and higher recall compared to searching a single global index and filtering afterward.

## Running Vector Similarity Search Queries

Once your container is configured and data is loaded, you search using the `VectorDistance` system function:

```sql
SELECT TOP 10
    c.id,
    c.title,
    c.category,
    VectorDistance(c.contentVector, @queryVector) AS similarityScore
FROM c
ORDER BY VectorDistance(c.contentVector, @queryVector)
```

A few things to note:

- **Always use `TOP N`**: Without it, the engine tries to return all results, driving up RUs and latency dramatically.
- **Combine with filters**: You can add `WHERE` clauses to narrow the search. For example, `WHERE c.category = "electronics"` restricts the vector search to electronics items.
- **Project the score**: Aliasing `VectorDistance(...)` as `similarityScore` lets you inspect how close each result is.
- **Use `ORDER BY`**: The `ORDER BY VectorDistance(...)` clause sorts results by similarity (most similar first for cosine).

You can also apply a similarity threshold:

```sql
SELECT TOP 10 *
FROM c
WHERE VectorDistance(c.contentVector, @queryVector) > 0.8
ORDER BY VectorDistance(c.contentVector, @queryVector)
```

## Hybrid Search: Combining Vector + Keyword + Filters

Vector search is powerful for semantic similarity, but sometimes you also want exact keyword matching—a product name, a specific error code, an exact phrase. *Hybrid search* fuses both approaches using the Reciprocal Rank Fusion (RRF) function.

Hybrid search requires both a **vector index** and a **full-text index** on your container. You also need a **full-text policy**:

```json
{
  "defaultLanguage": "en-US",
  "fullTextPaths": [
    {
      "path": "/content",
      "language": "en-US"
    }
  ]
}
```

And the corresponding indexing policy:

```json
{
  "indexingMode": "consistent",
  "automatic": true,
  "includedPaths": [{ "path": "/*" }],
  "excludedPaths": [
    { "path": "/_etag/?" },
    { "path": "/contentVector/*" }
  ],
  "fullTextIndexes": [
    { "path": "/content" }
  ],
  "vectorIndexes": [
    { "path": "/contentVector", "type": "diskANN" }
  ]
}
```

Then you run a hybrid query using `RRF`:

```sql
SELECT TOP 10 *
FROM c
ORDER BY RANK RRF(
    VectorDistance(c.contentVector, @queryVector),
    FullTextScore(c.content, "machine", "learning", "transformer")
)
```

The `RRF` function merges the rankings from both scoring methods into a single, unified ranking. Documents that score well on *both* vector similarity and keyword relevance float to the top.

### Weighted Hybrid Search

You can weight the two signals differently. For example, to make vector search twice as important:

```sql
SELECT TOP 10 *
FROM c
ORDER BY RANK RRF(
    VectorDistance(c.contentVector, @queryVector),
    FullTextScore(c.content, "machine", "learning"),
    [2, 1]
)
```

The weights array `[2, 1]` assigns weight 2 to the vector score and weight 1 to the full-text score.

## Semantic Reranker (Preview)

Even with hybrid search, the top results might not be ordered by *true relevance* to the user's intent. The Semantic Reranker—currently in gated preview—uses a Microsoft AI model to rescore and reorder your query results based on semantic relevance to a provided search phrase or context.

The reranker works with any query results—vector, full-text, or hybrid. It's integrated directly into the Cosmos DB SDKs (Python and .NET) with minimal code changes. Each reranked document receives a relevancy score from 0 to 1, and the results are reordered accordingly.

The trade-off is latency: the reranker adds an extra network call and model inference time. It's worth evaluating whether the improved relevancy justifies the added latency for your specific workload. For RAG applications where precision matters—support bots, legal search, medical Q&A—it can significantly improve the quality of the context passed to your LLM.

## Full-Text Search Indexing Policy

We briefly covered full-text configuration above, but let's go deeper. Full-text search in Cosmos DB includes tokenization, stemming, stop-word removal, and BM25 scoring—the same ranking algorithm used by most search engines.

The full-text query functions include:

- **`FullTextContains(c.text, "phrase")`**: Returns true if the phrase appears in the property. Use in `WHERE` clauses.
- **`FullTextContainsAll(c.text, "term1", "term2")`**: Returns true only if *all* terms appear.
- **`FullTextContainsAny(c.text, "term1", "term2")`**: Returns true if *any* term appears.
- **`FullTextScore(c.text, "term1", "term2")`**: Returns a BM25 relevance score. Used only in `ORDER BY RANK`.

Multi-language support (preview) covers English, German, Spanish, French, Italian, and Portuguese, with language-specific tokenization and stemming.

## Building a RAG Application with Cosmos DB and Azure OpenAI

Let's put it all together. Here's the high-level architecture of a RAG application:

1. **Ingest**: Load your documents into Cosmos DB. For each document, call Azure OpenAI's embedding API to generate a vector, and store both the text and the vector in the same item.
2. **Index**: Your container's DiskANN vector index handles the indexing automatically.
3. **Query**: When a user asks a question, embed the question using the same model, then run a vector search (or hybrid search) to retrieve the top-K most relevant documents.
4. **Generate**: Pass the retrieved documents as context to an Azure OpenAI chat completion model (like GPT-4o) along with the user's question. The model generates an answer grounded in your data.

A simplified document might look like:

```json
{
  "id": "doc-001",
  "title": "Return Policy",
  "content": "Items may be returned within 30 days of purchase...",
  "category": "policies",
  "contentVector": [0.0123, -0.0456, 0.0789, ...]
}
```

The query step:

```sql
SELECT TOP 5
    c.id, c.title, c.content,
    VectorDistance(c.contentVector, @questionVector) AS relevance
FROM c
WHERE c.category = "policies"
ORDER BY VectorDistance(c.contentVector, @questionVector)
```

Then you feed `c.content` from the top results into your LLM prompt as context. The result is a conversational AI that answers questions accurately from your own data.

## Using Cosmos DB for LLM Conversation History

Every chat-based AI application needs to maintain conversation history. The LLM itself is stateless—you must pass the full conversation context with each request. Cosmos DB is an excellent store for this.

The recommended data model stores **one document per turn**, where each turn represents a complete exchange (user prompt + agent response):

```json
{
  "id": "turn-00a1b2c3",
  "threadId": "thread-5678",
  "turnIndex": 3,
  "messages": [
    {
      "role": "user",
      "content": "What's our refund policy for accessories?",
      "timestamp": "2025-09-24T10:14:25Z"
    },
    {
      "role": "agent",
      "content": "Accessories can be returned within 30 days...",
      "timestamp": "2025-09-24T10:14:27Z"
    }
  ],
  "embedding": [0.013, -0.092, 0.551, ...]
}
```

Use `threadId` as your partition key so all turns in a conversation are colocated. Retrieving the last N turns for context injection is a simple query:

```sql
SELECT TOP @k c.messages, c.turnIndex
FROM c
WHERE c.threadId = @threadId
ORDER BY c.turnIndex DESC
```

You can also store an embedding per turn to enable *semantic caching*—if a new question is very similar to a previous one, you can return the cached response without calling the LLM again, saving both latency and token costs.

## Building AI Agent State Stores

AI agents go beyond simple Q&A. They plan, use tools, make decisions, and execute multi-step workflows. All of that requires persistent state—and Cosmos DB's schema-flexible, globally distributed nature makes it an ideal agent state store.

You can store:

- **Current task state**: What step the agent is on, what tools it has called, intermediate results.
- **Tool call logs**: The inputs and outputs of every tool invocation, for debugging and replay.
- **Planning context**: The agent's goals, sub-goals, and decision history.
- **Multi-agent coordination**: In multi-agent systems, shared state that multiple agents read from and write to.

The partition key strategy matters here. For single-agent apps, partition by `threadId` or `sessionId`. For multi-tenant agent platforms, consider hierarchical partition keys like `["/tenantId", "/threadId"]` to balance isolation with performance.

## Managing AI Agent Memories

Agent memory is a step beyond conversation history. It's about giving agents the ability to *learn* and *remember* across interactions.

### Short-Term (Working) Memory

Short-term memory holds the current context: recent conversation turns, in-progress tool call results, and intermediate reasoning steps. It's ephemeral—you might expire it with TTL after the session ends, or summarize it into long-term memory.

### Long-Term Memory

Long-term memory persists across sessions and conversations. It captures user preferences ("User prefers bullet-point responses"), learned facts ("User is based in Seattle"), and historical summaries of past interactions. This memory makes agents feel personalized and intelligent over time.

### Memory Retrieval Patterns

Cosmos DB supports multiple retrieval strategies for agent memories:

**Recency-based**: Get the most recent turns.

```sql
SELECT TOP @k c.content, c.timestamp
FROM c
WHERE c.threadId = @threadId
ORDER BY c.timestamp DESC
```

**Semantic search**: Find the most contextually relevant memories, regardless of when they occurred.

```sql
SELECT TOP @k c.content, VectorDistance(c.embedding, @queryVector) AS relevance
FROM c
WHERE c.threadId = @threadId
ORDER BY VectorDistance(c.embedding, @queryVector)
```

**Hybrid retrieval**: Combine semantic similarity with keyword matching for the best of both worlds.

```sql
SELECT TOP @k c.content
FROM c
WHERE c.threadId = @threadId
ORDER BY RANK RRF(
    VectorDistance(c.embedding, @queryVector),
    FullTextScore(c.content, @searchTerms)
)
```

**Keyword filtering**: Find memories that mention specific terms.

```sql
SELECT TOP 10 *
FROM c
WHERE c.threadId = @threadId
  AND FullTextContains(c.content, "refund policy")
```

## Building Knowledge Graphs with Cosmos DB

Sometimes vector similarity and keyword search aren't enough. When your data has rich, structured relationships—organizational hierarchies, dependency trees, supply chains—you need graph traversal. That's where knowledge graphs come in.

The **CosmosAIGraph** project (available at [aka.ms/cosmosaigraph](https://aka.ms/cosmosaigraph)) demonstrates how to build AI-powered knowledge graphs using Cosmos DB. It combines three retrieval methods:

- **Database RAG**: Traditional document queries for factual lookups.
- **Vector RAG**: Semantic similarity for finding conceptually related items.
- **Graph RAG**: Graph traversal for relationship and path queries.

CosmosAIGraph features *OmniRAG*, which dynamically selects the best retrieval method based on user intent. A question like "What is Flask?" triggers a database query. "What are its dependencies?" triggers a graph traversal. "Find libraries similar to Flask" triggers vector search. This multi-modal approach yields more comprehensive and accurate answers than any single method alone.

You can model graph-like data directly in Cosmos DB for NoSQL using document references and adjacency lists, or use Cosmos DB for Apache Gremlin for native graph operations. The choice depends on your query patterns and whether you need full graph traversal capabilities or simpler relationship lookups.

## Integrating with AI Frameworks

Cosmos DB offers official integrations with the three major AI/LLM orchestration frameworks. You don't need to build the plumbing from scratch.

### Semantic Kernel

Microsoft's [Semantic Kernel](https://learn.microsoft.com/semantic-kernel/overview/) provides a Cosmos DB connector for:

- **Vector store**: Use Cosmos DB as the backing store for Semantic Kernel's memory and vector search abstractions.
- **Chat history**: Persist conversation state through the Cosmos DB chat history connector.
- **Agent memory**: Store and retrieve agent memories using Semantic Kernel's memory pipeline.

Available for both .NET and Python.

### LangChain

[LangChain](https://www.langchain.com/) integrates with Cosmos DB through:

- **Vector store**: The `AzureCosmosDBVectorSearch` class in LangChain connects directly to Cosmos DB for NoSQL for vector storage and similarity search.
- **Chat history**: The `CosmosDBChatMessageHistory` class manages conversation history.
- **Caching**: Use Cosmos DB as an LLM response cache to reduce token costs.

Available for Python and JavaScript/TypeScript.

### LlamaIndex

[LlamaIndex](https://www.llamaindex.ai/) provides a Cosmos DB integration for:

- **Vector store**: The `AzureCosmosDBNoSQLVectorSearch` class enables vector storage and retrieval.
- **Document storage**: Use Cosmos DB as a document store backing LlamaIndex's data ingestion pipeline.

Available for Python.

All three frameworks let you swap in Cosmos DB with minimal configuration changes, so you can experiment and choose the orchestration layer that fits your team best.

## Model Context Protocol (MCP) Toolkit for Cosmos DB

The [Azure Cosmos DB MCP Toolkit](https://github.com/AzureCosmosDB/MCPToolKit) is an open-source solution that enables AI agents and agentic applications to interact with Cosmos DB through the **Model Context Protocol (MCP)**. MCP is an emerging standard for how AI tools and agents communicate with external data sources.

The toolkit provides enterprise-ready tools that let AI agents:

- Query and search your Cosmos DB data (including vector search).
- Read and write documents.
- Manage containers and databases.
- Execute transactional operations.

This is particularly useful when you're building agents that need to *act* on data in Cosmos DB—not just read it, but create, update, and query it dynamically as part of their reasoning process. The MCP toolkit bridges the gap between your agent's decision-making layer and your database, using a standardized protocol that works across different agent frameworks.

## AI Coding Assistants: Agent Kit

The [Azure Cosmos DB Agent Kit](https://github.com/AzureCosmosDB/cosmosdb-agent-kit) is a different kind of AI tool—it's not for your application's end users, but for *you* as a developer. It's an open-source collection of 45+ curated rules that teaches AI coding assistants expert-level Cosmos DB best practices.

Built on the [Agent Skills](https://agentskills.io/) format, it works with:

- **GitHub Copilot** (VS Code, Visual Studio, JetBrains)
- **Claude Code**
- **Gemini CLI**
- Any other Agent Skills-compatible tool

Install with one command:

```bash
npx skills add AzureCosmosDB/cosmosdb-agent-kit
```

Once installed, the skills activate automatically when your AI assistant detects Cosmos DB-related code. Ask it to review your data model, optimize a query, or check your SDK usage patterns, and it applies production-tested best practices covering:

| Category | Priority |
|---|---|
| Data Modeling | Critical |
| Partition Key Design | Critical |
| Query Optimization | High |
| SDK Best Practices | High |
| Indexing Strategies | Medium-High |
| Throughput & Scaling | Medium |
| Global Distribution | Medium |
| Monitoring & Diagnostics | Low-Medium |

Think of it as having a Cosmos DB expert sitting next to you while you code—except the expert never sleeps and is always up to date with the latest guidance.

## Putting It All Together

The AI landscape is moving fast, but the data layer underneath it all follows a clear pattern: you need a database that can store your operational data, your vectors, your conversation history, and your agent state—with low latency, high throughput, and global availability. Cosmos DB checks every one of those boxes.

Whether you're building a simple RAG chatbot or a complex multi-agent system with long-term memory and knowledge graphs, the building blocks are here. Vector search with DiskANN gives you the retrieval performance. Hybrid search and the semantic reranker give you the relevancy. The integrations with Semantic Kernel, LangChain, and LlamaIndex give you the developer experience. And the MCP toolkit and Agent Kit give you the operational tooling to build and maintain it all.

The key insight is this: by consolidating your AI data layer into Cosmos DB, you eliminate an entire category of operational complexity. No more synchronizing data between stores. No more managing separate vector databases. No more worrying about consistency between your transactional data and your AI retrieval layer. One database. One set of SLAs. One operational story.

## What's Next

In **Chapter 25**, we'll shift our focus to **multi-tenancy patterns** — the isolation spectrum from shared containers to dedicated accounts, partition key strategies for tenant isolation, hierarchical partition keys for high-cardinality tenant scenarios, enforcing data isolation with RBAC and resource tokens, per-tenant throughput management, and orchestrating multi-account deployments at scale with Cosmos DB Fleets.
