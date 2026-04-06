# Chapter 25: Vector Search and AI Applications

Most databases bolt on AI features as an afterthought — a separate vector index here, a plugin there, another service to synchronize. Cosmos DB takes a different approach. Your operational data and your vector embeddings live in the same container, indexed by the same engine, with the same reliability guarantees.

This chapter is the canonical home for everything AI in Cosmos DB: vector search, hybrid queries, RAG patterns, agent memory, framework integrations, and the tooling ecosystem growing around it. If you're building anything that touches an LLM, an embedding model, or an AI agent, you're in the right place.

## Cosmos DB as a Unified AI Database

The typical AI application architecture looks like this: operational data in one database, vector embeddings in a dedicated vector database, and an ETL pipeline keeping them in sync. That pipeline is a liability. It introduces latency, eventual consistency between your real data and your embeddings, and an entire category of bugs where the two stores disagree.

Cosmos DB eliminates that pipeline. You store a product document — name, price, description, category — and its vector embedding in the *same item*. When the product description changes, you update the embedding in the same write operation. When you query, you can filter on price, sort by vector similarity, and full-text search the description, all in a single query against a single container. <!-- Source: build-ai-applications/why-cosmos-ai.md -->

## What Is Vector Search?

If you're new to the embedding-and-search paradigm, here's the short version. An **embedding** is a mathematical representation of data — text, images, audio — as an array of floating-point numbers. An embedding model (like OpenAI's `text-embedding-3-large` or Azure AI's equivalents) converts your content into a high-dimensional vector where *semantic similarity maps to geometric proximity*. Documents about similar topics end up near each other in vector space, even if they don't share a single keyword. <!-- Source: build-ai-applications/learn-core-ai-concepts/vector-embeddings.md -->

**Vector search** finds the items whose embeddings are closest to a query embedding. You convert the user's question into a vector, then ask the database: "Give me the 10 items whose vectors are nearest to this one." The distance between vectors is computed using a **distance function** — cosine similarity, Euclidean distance, or dot product — and the closest results are the most semantically relevant.

This is the foundation of **Retrieval-Augmented Generation (RAG)**: instead of asking an LLM to answer from memory (where it hallucinates), you retrieve relevant documents via vector search and pass them to the LLM as grounding context. The LLM generates a response based on *your* data, not its training corpus. <!-- Source: build-ai-applications/learn-core-ai-concepts/rag.md -->

## Configuring Vector Embeddings on a Container

Before you can run vector queries, you need to tell Cosmos DB which properties contain vectors and how to handle them. This is done through a **container vector policy** — a JSON configuration you set at container creation time.

The vector policy specifies four things for each vector path: <!-- Source: build-ai-applications/use-vector-search/vector-search.md -->

| Setting | Purpose | Options |
|---|---|---|
| **`path`** | Property holding vector | e.g., `/contentVector` |
| **`dataType`** | Element numeric type | `float32`, `float16`, `int8`, `uint8` |
| **`dimensions`** | Dimensions per vector | Default 1536; max varies |
| **`distanceFunction`** | Similarity measure | `cosine`, `dotproduct`, `euclidean` |

- **`dimensions`**: Max is 505 for `flat` indexes, 4,096 for `quantizedFlat` and `diskANN`.
- **`distanceFunction`**: Default is `cosine`.

Here's a concrete vector policy for a container that stores product embeddings:

```json
{
    "vectorEmbeddings": [
        {
            "path": "/contentVector",
            "dataType": "float32",
            "distanceFunction": "cosine",
            "dimensions": 1536
        }
    ]
}
```

You can define multiple vector paths on the same container — one for text embeddings, another for image embeddings — as long as each targets a different path. <!-- Source: build-ai-applications/use-vector-search/vector-search.md -->

### Vector Data Types

Your choice of data type is a storage-versus-precision tradeoff:

| Type | Bytes | Notes |
|---|---|---|
| **`float32`** | 4 | Default; most model outputs |
| **`float16`** | 2 | Half storage, minimal loss |
| **`int8`** | 1 | Native int8 models |
| **`uint8`** | 1 | Unsigned quantized |

<!-- Source: build-ai-applications/use-vector-search/vector-search.md -->

Most embedding models output `float32` vectors. If you're looking to reduce storage costs and your workload can tolerate a small accuracy reduction, `float16` is a practical choice — it halves the storage footprint per vector.

### Distance Functions

The three distance functions measure similarity differently: <!-- Source: build-ai-applications/use-vector-search/vector-search.md -->

| Function | Range | Similarity |
|---|---|---|
| **Cosine** | -1 to +1 | Higher = more similar |
| **Dot product** | -∞ to +∞ | Higher = more similar |
| **Euclidean** | 0 to +∞ | Lower = more similar |

- **Cosine** is the default and right choice for most text embeddings — it handles unnormalized vectors gracefully.
- **Dot product** works best when vectors are already normalized or the model is optimized for it.
- **Euclidean** measures straight-line distance in vector space.

For text embeddings from OpenAI or Azure OpenAI models, **cosine** is the standard choice. It's the default for a reason — it handles unnormalized vectors gracefully and aligns with how most embedding models are trained.

### Dimensions and Model Selection

The `dimensions` setting must match the output of your embedding model. Here are common models and their dimensions:

| Model | Dims | Notes |
|---|---|---|
| OpenAI `text-embedding-3-large` | 3072 | Supports dimension reduction |
| OpenAI `text-embedding-3-small` | 1536 | Good quality/cost balance |
| OpenAI `text-embedding-ada-002` | 1536 | Legacy; widely deployed |
| Azure AI `text-embedding-3-large` | 3072 | Azure-hosted OpenAI model |

The newer `text-embedding-3-*` models let you request fewer dimensions at embedding time (e.g., 256 or 512), trading some accuracy for lower storage and faster queries. If you're cost-constrained, this is worth experimenting with.

## Vector Indexing with DiskANN

Storing vectors is only half the story — you also need to *index* them for fast retrieval. Cosmos DB offers three vector index types, each targeting a different scale. The full indexing policy configuration is covered in Chapter 9; here we focus on how each index type behaves during search. <!-- Source: build-ai-applications/use-vector-search/vector-search.md -->

| Index Type | Max Dims | Best For |
|---|---|---|
| **`flat`** | 505 | Small data; exact kNN |
| **`quantizedFlat`** | 4,096 | Up to ~50K vectors/partition |
| **`diskANN`** | 4,096 | 50K+ vectors; best perf |

- **`flat`**: Brute-force exact search — guarantees 100% recall.
- **`quantizedFlat`**: Brute-force over compressed (quantized) vectors.
- **`diskANN`**: Approximate nearest neighbor (ANN) — lowest latency, highest throughput.

<!-- Source: build-ai-applications/use-vector-search/vector-search.md -->

### Flat: Exact Search

The `flat` index stores vectors alongside your other indexed properties and scans them exhaustively. It guarantees 100% recall — you'll always find the true nearest neighbors. The tradeoff is that it's limited to 505 dimensions and gets expensive as the dataset grows. Use it for small, focused search spaces or when you're filtering down to a narrow partition first.

### DiskANN: Approximate Nearest Neighbor at Scale

**DiskANN** is the production workhorse. Developed by Microsoft Research, it's a graph-based indexing algorithm that stores compressed vectors in memory while keeping full vectors and the graph structure on high-speed SSDs. This architecture gives you fast, accurate search at any scale — from tens of thousands to billions of vectors. <!-- Source: build-ai-applications/why-cosmos-ai.md -->

DiskANN isn't experimental technology. It powers vector search inside Microsoft's own web search, advertising, and the Microsoft 365 and Windows Copilot runtimes. When you use DiskANN in Cosmos DB, you're using the same infrastructure. <!-- Source: build-ai-applications/why-cosmos-ai.md -->

One important requirement: both `quantizedFlat` and `diskANN` indexes need at least 1,000 vectors before they produce indexed results. Below that threshold, the engine falls back to a full scan instead. This is to ensure the quantization process has enough data to be accurate. <!-- Source: build-ai-applications/use-vector-search/vector-search.md -->

### Sharded DiskANN for Multi-Tenant Scenarios

Standard DiskANN creates one index per physical partition. In multi-tenant workloads, that means every tenant's vectors are mixed in the same index — a query for Tenant A still traverses Tenant B's vectors. **Sharded DiskANN** solves this by creating separate DiskANN indexes per shard key value. <!-- Source: build-ai-applications/use-vector-search/sharded-diskann.md -->

You configure it by adding a `vectorIndexShardKey` to the vector index in your indexing policy:

```json
"vectorIndexes": [
    {
        "path": "/contentVector",
        "type": "DiskANN",
        "vectorIndexShardKey": ["/tenantId"]
    }
]
```

This creates a distinct DiskANN index for each unique `tenantId` value. When you query with a `WHERE c.tenantId = "tenant1"` filter, the search runs against only that tenant's index — smaller, faster, cheaper, and with better recall because the search space is more focused. <!-- Source: build-ai-applications/use-vector-search/sharded-diskann.md -->

The shard key can be any property, not just the partition key. Common choices include tenant ID, category, region, or any attribute that naturally segments your vector data. For a deeper discussion of multi-tenant vector search patterns, see Chapter 26.

## Running Vector Similarity Search Queries

Once your container has a vector policy and index, querying is straightforward. You use the `VectorDistance` system function:

```sql
SELECT TOP 10 c.title, c.description,
    VectorDistance(c.contentVector, [0.013, -0.092, 0.551, ...]) AS SimilarityScore
FROM c
ORDER BY VectorDistance(c.contentVector, [0.013, -0.092, 0.551, ...])
```

This returns the 10 items whose `contentVector` is closest to the provided query vector, ordered from most similar to least similar. The `SimilarityScore` alias lets you see how close each result is. <!-- Source: build-ai-applications/use-vector-search/vector-search.md -->

**Always include a `TOP N` clause.** Without it, the query attempts to return far more results than you need, consuming more RUs and adding latency. <!-- Source: build-ai-applications/use-vector-search/vector-search.md -->

You can combine vector search with standard `WHERE` filters to scope the search:

```sql
SELECT TOP 10 c.title, VectorDistance(c.contentVector, @queryVector) AS score
FROM c
WHERE c.category = "electronics" AND c.price < 500
ORDER BY VectorDistance(c.contentVector, @queryVector)
```

This is a powerful pattern: use scalar filters to narrow the candidate set, then rank by vector similarity within that set.

In the Python SDK, a parameterized vector query looks like this:

```python
query = """
    SELECT TOP @k c.title, c.description,
        VectorDistance(c.contentVector, @embedding) AS SimilarityScore
    FROM c
    ORDER BY VectorDistance(c.contentVector, @embedding)
"""

results = container.query_items(
    query=query,
    parameters=[
        {"name": "@k", "value": 10},
        {"name": "@embedding", "value": query_vector}
    ],
    enable_cross_partition_query=True
)
```

## Hybrid Search: Combining Vector and Full-Text Queries

Vector search is excellent at semantic similarity but blind to exact keywords. Full-text search is great at keyword matching but doesn't understand meaning. **Hybrid search** combines both using Reciprocal Rank Fusion (RRF), giving you the best of both worlds. <!-- Source: build-ai-applications/hybrid-search.md -->

Hybrid search requires both a vector index and a full-text index on your container (see Chapter 9 for indexing policy setup), plus a full-text policy that defines which paths contain searchable text:

```json
{
    "defaultLanguage": "en-US",
    "fullTextPaths": [
        {
            "path": "/description",
            "language": "en-US"
        }
    ]
}
```

Then use the `RRF` function in an `ORDER BY RANK` clause:

```sql
SELECT TOP 10 *
FROM c
ORDER BY RANK RRF(
    VectorDistance(c.contentVector, @queryVector),
    FullTextScore(c.description, "wireless", "noise", "cancelling")
)
```

The `RRF` function merges the rankings from vector similarity and BM25 full-text scoring into a single unified ranking. Documents that score well on *both* criteria bubble to the top. <!-- Source: build-ai-applications/hybrid-search.md -->

### Weighted Hybrid Search

Not all signals are equally important. You can weight the components by passing an array of weights as the last argument to `RRF`:

```sql
SELECT TOP 10 *
FROM c
ORDER BY RANK RRF(
    VectorDistance(c.contentVector, @queryVector),
    FullTextScore(c.description, "wireless", "noise", "cancelling"),
    [2, 1]
)
```

Here, the vector similarity score is weighted 2× relative to the BM25 keyword score. Adjust these weights based on your workload — semantic-heavy applications lean toward vector weight, while keyword-precision applications lean toward full-text weight. <!-- Source: build-ai-applications/hybrid-search.md -->

## Semantic Reranker (Preview)

Even with hybrid search, the initial retrieval ranking can miss nuances of user intent. The **Semantic Reranker** adds an AI-powered scoring pass *after* your initial query — whether that's vector, full-text, or hybrid — to reorder results based on their *relevancy* to the user's search phrase. <!-- Source: build-ai-applications/semantic-reranker.md -->

The Semantic Reranker uses the Microsoft AI Semantic Ranker model (the same model available in Azure AI Search) to evaluate each result against your provided context string. Each document gets a relevancy score from 0 to 1, and the results are reordered accordingly. <!-- Source: build-ai-applications/semantic-reranker.md -->

This is a trade-off worth understanding: the reranker introduces an additional network call and model inference step, which increases overall query latency. It's not a free upgrade to every query. Where it shines is ambiguous queries — a user searching "how to cancel" could mean a subscription, an order, or a meeting, and the reranker uses the full result text to surface the right intent. Test it against your specific workload — measure retrieval quality (precision@k, nDCG) both with and without the reranker to decide if the relevancy improvement justifies the latency cost. <!-- Source: build-ai-applications/semantic-reranker.md -->

The Semantic Reranker works with the latest Python and .NET Cosmos DB SDKs and requires minimal code changes. As of this writing, it's available in gated preview — you'll need to [sign up for access](https://aka.ms/AzureCosmosDB/RerankerPreview). <!-- Source: build-ai-applications/semantic-reranker.md -->

## Full-Text Search for AI Workloads

Full-text search in Cosmos DB isn't just for traditional keyword queries — it's a critical building block for AI applications that need precise lexical matching alongside semantic search. The indexing policy configuration lives in Chapter 9, and the query functions are covered in Chapter 8. Here we focus on the AI-specific patterns.

Cosmos DB's full-text search uses **BM25** (Best Matching 25) scoring with linguistic processing: stemming, tokenization, stop word removal, and case normalization. Four system functions give you control over text matching: <!-- Source: build-ai-applications/full-text-indexing-and-search/full-text-search.md -->

| Function | Purpose | Clause |
|---|---|---|
| `FullTextContains` | Property has phrase | `WHERE` |
| `FullTextContainsAll` | All terms must appear | `WHERE` |
| `FullTextContainsAny` | Any term must appear | `WHERE` |
| `FullTextScore` | BM25 relevance score | `ORDER BY RANK` |

All functions take a property path as the first argument, followed by one or more search terms — e.g., `FullTextContains(c.description, "wireless")`.

<!-- Source: build-ai-applications/full-text-indexing-and-search/full-text-search.md -->

A practical AI example: filtering agent memory for conversations that mention specific topics before running a vector similarity search:

```sql
SELECT TOP 10 c.content, c.timestamp
FROM c
WHERE c.threadId = @threadId
    AND FullTextContains(c.content, "refund policy")
ORDER BY RANK FullTextScore(c.content, "refund", "policy")
```

Full-text search currently supports English (`en-US`) and a growing set of additional language codes in early preview: `de-DE` (German), `es-ES` (Spanish), `fr-FR` (French), `it-IT` (Italian), `pt-PT` (Portuguese), and `pt-BR` (Brazilian Portuguese) — seven codes total. Multi-language support requires opt-in via the *New features for full-text search* feature in the **Features** blade of your Cosmos DB resource in the Azure portal, and stopword removal is currently available only for English. Fuzzy search (tolerating typos up to 2 edits) is also available in early preview under the same opt-in. <!-- Source: build-ai-applications/full-text-indexing-and-search/full-text-search.md -->

## Semantic Cache: Cosmos DB as an LLM Response Cache

LLM calls are slow and expensive. A **semantic cache** uses vector search to short-circuit them: before sending a prompt to the LLM, you vectorize the user's query and search for a similar *previous* query in your cache. If you find one above a similarity threshold, you return the cached completion instead of calling the LLM again. <!-- Source: build-ai-applications/learn-core-ai-concepts/semantic-cache.md -->

This isn't a traditional key-value cache. A string-equality cache only hits on *exact* matches. A semantic cache hits on *similar* queries — "What's the refund policy?" and "How do I get a refund?" can both return the same cached answer because their embeddings are close in vector space. <!-- Source: build-ai-applications/learn-core-ai-concepts/semantic-cache.md -->

The implementation in Cosmos DB is simple: a dedicated container (or the same container) with a vector policy on the cached prompt embeddings. The flow is:

1. User sends a prompt.
2. Generate an embedding for the prompt.
3. Vector search the cache container for similar previous prompts (e.g., similarity > 0.99).
4. **Cache hit:** Return the cached completion instantly.
5. **Cache miss:** Call the LLM, then store the prompt embedding + completion in the cache.

```python
def get_cache(container, vectors, similarity_score=0.99, num_results=1):
    results = container.query_items(
        query="""
        SELECT TOP @num_results *
        FROM c
        WHERE VectorDistance(c.vector, @embedding) > @similarity_score
        ORDER BY VectorDistance(c.vector, @embedding)
        """,
        parameters=[
            {"name": "@embedding", "value": vectors},
            {"name": "@num_results", "value": num_results},
            {"name": "@similarity_score", "value": similarity_score},
        ],
        enable_cross_partition_query=True
    )
    return list(results)
```

<!-- Source: build-ai-applications/rag-chatbot.md -->

One subtlety: a semantic cache should operate within a **context window**, not on isolated prompts. If User A asks "What's the largest lake in North America?" (answer: Lake Superior) and then "What's the second largest?", the cache should key on the *sequence* of prompts, not just the last one. Otherwise, a different user asking "What's the second largest?" in a different context will get the wrong cached answer. <!-- Source: build-ai-applications/learn-core-ai-concepts/semantic-cache.md -->

Use **TTL (time-to-live)** on cache items to keep the cache fresh and bounded. You can also implement a hit counter via patch operations to preserve frequently-accessed entries while expiring stale ones.

## Building a RAG Application

RAG (Retrieval-Augmented Generation) is the pattern that turns Cosmos DB from a database into the knowledge backbone of an AI application. Here's the end-to-end flow with Cosmos DB and Azure OpenAI: <!-- Source: build-ai-applications/learn-core-ai-concepts/rag.md -->

**Step 1: Ingest and embed your data.** Store your documents in Cosmos DB with their vector embeddings. Use your embedding model to generate vectors at write time:

```python
from openai import AzureOpenAI

openai_client = AzureOpenAI(
    azure_endpoint=endpoint, api_key=key, api_version="2023-05-15"
)

def generate_embedding(text):
    response = openai_client.embeddings.create(
        input=text,
        model="text-embedding-3-large",
        dimensions=1536
    )
    return response.data[0].embedding

# Store document with its embedding
doc = {
    "id": "product-4821",
    "name": "ProFit Wireless Headphones",
    "description": "Noise-cancelling over-ear headphones with 40-hour battery...",
    "category": "electronics",
    "price": 149.99,
    "contentVector": generate_embedding("Noise-cancelling over-ear headphones...")
}
container.upsert_item(doc)
```

**Step 2: Retrieve relevant documents.** When a user asks a question, generate an embedding for the question and vector-search your container:

```python
user_question = "What headphones have the best battery life?"
query_vector = generate_embedding(user_question)

results = container.query_items(
    query="""
        SELECT TOP 5 c.name, c.description, c.price
        FROM c
        ORDER BY VectorDistance(c.contentVector, @embedding)
    """,
    parameters=[{"name": "@embedding", "value": query_vector}],
    enable_cross_partition_query=True
)
relevant_docs = list(results)
```

**Step 3: Generate a grounded response.** Pass the retrieved documents to the LLM as context:

```python
system_prompt = """You are a helpful product assistant. Answer the user's
question based only on the provided product information."""

messages = [{"role": "system", "content": system_prompt}]
for doc in relevant_docs:
    messages.append({"role": "system", "content": json.dumps(doc)})
messages.append({"role": "user", "content": user_question})

response = openai_client.chat.completions.create(
    model="gpt-4o",
    messages=messages,
    temperature=0.1
)
```

The LLM now generates a response grounded in your actual product data — not its training corpus. This is RAG in three steps.

## LLM Conversation History and Memory

Every conversational AI application needs to track what's been said. Cosmos DB is a natural fit for this — you're already using it for your data and embeddings, so storing conversation history here keeps everything in one place.

The recommended data model is **one document per turn**, where each item represents a complete exchange (user prompt + agent response) within a conversation thread: <!-- Source: build-ai-applications/agentic-memories.md -->

```json
{
    "id": "turn-7a2b",
    "threadId": "thread-1234",
    "turnIndex": 7,
    "messages": [
        {
            "role": "user",
            "content": "What's your refund policy for accessories?",
            "timestamp": "2025-09-24T10:14:25Z"
        },
        {
            "role": "agent",
            "content": "Accessories can be returned within 30 days if unopened...",
            "timestamp": "2025-09-24T10:14:27Z"
        }
    ],
    "embedding": [0.013, -0.092, 0.551]
}
```

Use `threadId` as your partition key to colocate all turns in a conversation. Retrieving the last *k* turns for context injection is a single, efficient query:

```sql
SELECT TOP @k c.messages, c.turnIndex
FROM c
WHERE c.threadId = @threadId
ORDER BY c.turnIndex DESC
```

This model gives you several advantages:

- Easy retrieval of recent context
- Per-turn TTL for expiring old memories
- Per-turn vector embeddings for semantic search within a conversation
- Small item sizes that keep RU costs predictable

<!-- Source: build-ai-applications/agentic-memories.md -->

For multi-tenant applications, use a hierarchical partition key of `["/tenantId", "/threadId"]` to group threads by tenant while maintaining per-thread locality. This enables efficient tenant-level queries (e.g., "find all conversations for this tenant about billing") without cross-partition scans. <!-- Source: build-ai-applications/agentic-memories.md -->

## Building AI Agent State Stores

AI agents need to persist more than conversation history. They need to track in-progress tasks, intermediate results from tool calls, pending decisions, and workflow state. Cosmos DB's schema-agnostic design makes it well-suited for agent state — each agent's state document can have whatever structure the workflow requires without a schema migration.

The key design principle: partition by the unit you query most frequently. If your agent processes tasks independently, partition by task ID. If agents are scoped to user sessions, partition by session ID. If you're running multi-agent workflows where agents collaborate on a shared thread, `threadId` keeps all state colocated. <!-- Source: build-ai-applications/agentic-memories.md -->

Use TTL aggressively for ephemeral state. An agent's intermediate tool call results probably don't need to live forever — set a TTL to automatically clean up after the workflow completes.

## Managing AI Agent Memories

Agent memory is the difference between a stateless chatbot and an AI that actually learns from interactions. Cosmos DB supports both **short-term** and **long-term** memory patterns: <!-- Source: build-ai-applications/agentic-memories.md -->

**Short-term (working) memory** holds the current context: recent conversation turns, tool call results, in-progress task state. It's scoped to a single thread or session and can be expired with TTL. This is what you feed into the LLM's context window for the current interaction.

**Long-term memory** persists across sessions and accumulates knowledge over time: user preferences ("prefers bullet lists"), behavioral patterns ("always asks about vegetarian options"), and summarized insights from past conversations. Long-term memories are typically created by summarizing or classifying short-term memories after a thread ends.

A practical memory retrieval strategy combines multiple patterns: <!-- Source: build-ai-applications/agentic-memories.md -->

1. **Recent turns** — recency-ordered query within the current thread.
2. **Semantic search** — vector similarity across past threads to find relevant context.
3. **Keyword search** — full-text search for specific entities or topics.
4. **Hybrid search** — RRF fusion of vector and full-text for best-of-both-worlds recall.

```sql
-- Hybrid memory retrieval: semantic + keyword
SELECT TOP @k c.content, c.timestamp
FROM c
WHERE c.threadId = @threadId
ORDER BY RANK RRF(
    VectorDistance(c.embedding, @queryVector),
    FullTextScore(c.content, @searchTerms)
)
```

<!-- Source: build-ai-applications/agentic-memories.md -->

## Building Knowledge Graphs for AI

When your AI needs to understand *relationships* between entities — organizational hierarchies, supply chain dependencies, social connections — vector search alone falls short. **Knowledge graphs** capture these structured relationships explicitly.

**CosmosAIGraph** is an open-source solution that builds AI-powered knowledge graphs on Cosmos DB for NoSQL. It combines traditional database queries, vector search, and graph traversal in what the project calls **OmniRAG**: the system dynamically selects the best retrieval strategy based on user intent. <!-- Source: build-ai-applications/cosmos-ai-graph.md -->

- "What is the Python Flask library?" → Database RAG (direct lookup).
- "What are its dependencies?" → Graph RAG (relationship traversal).
- "Find libraries similar to Flask" → Vector search (semantic similarity).

The practical value is that graph RAG can answer questions that vector search fundamentally can't — like tracing indirect connections between entities, navigating hierarchies, or following multi-hop paths through a dependency chain. Vector search finds *similar* things; graph traversal finds *related* things. The combination of both in a single Cosmos DB container gives AI applications a much richer retrieval toolkit. <!-- Source: build-ai-applications/cosmos-ai-graph.md -->

To get started, see the [CosmosAIGraph repository](https://aka.ms/cosmosaigraph).

## Integrating with AI Frameworks

You don't have to build RAG plumbing from scratch. Cosmos DB has dedicated connectors for the major AI orchestration frameworks. <!-- Source: build-ai-applications/integrations.md -->

| Framework | Languages | Connector |
|---|---|---|
| **Semantic Kernel** | C#, Python, Java | Vector store (Python + .NET) |
| **LangChain** | Python, JS, Java | Vector store (all langs) |
| **LangGraph** | Python | Checkpoint saver |
| **LlamaIndex** | Python | Vector store |
| **Spring AI** | Java | Vector store |

### Semantic Kernel

Microsoft's **Semantic Kernel** is an open-source framework for building AI agents that orchestrate code and LLM calls. The Cosmos DB connector plugs directly into Semantic Kernel's vector store abstraction — you configure it with your Cosmos DB endpoint, and Semantic Kernel handles embedding storage, retrieval, and memory management.

```csharp
using Microsoft.SemanticKernel.Connectors.AzureCosmosDBNoSQL;

var memoryStore = new AzureCosmosDBNoSQLMemoryStore(
    connectionString: cosmosConnectionString,
    databaseName: "ai-app",
    dimensions: 1536
);
```

### LangChain

**LangChain** is the most widely adopted Python framework for LLM applications. The Cosmos DB vector store integration works as a drop-in replacement for other vector stores:

```python
from langchain_community.vectorstores.azure_cosmos_db_no_sql import (
    AzureCosmosDBNoSqlVectorSearch
)

vector_store = AzureCosmosDBNoSqlVectorSearch(
    cosmos_client=cosmos_client,
    database_name="ai-app",
    container_name="products",
    embedding=embedding_model,
    vector_embedding_policy=vector_policy,
    indexing_policy=indexing_policy
)

# Similarity search
results = vector_store.similarity_search("wireless noise cancelling headphones", k=5)
```

LangChain also offers JavaScript and Java connectors for Cosmos DB, and the **LangGraph** library provides a Cosmos DB checkpoint saver for persisting state in multi-agent workflows.

### LlamaIndex

**LlamaIndex** focuses on building context-augmented AI applications. Its Cosmos DB connector works as a vector store backend for LlamaIndex's retrieval pipelines, letting you index and search your data using LlamaIndex's abstractions while Cosmos DB handles the storage and vector search.

All three frameworks abstract away the low-level vector policy and query syntax we covered earlier in this chapter. If you're already using one of these frameworks, the Cosmos DB connector is the fastest path to production.

## Model Context Protocol (MCP) Toolkit

The **Model Context Protocol (MCP) Toolkit** for Cosmos DB ([AzureCosmosDB/MCPToolKit](https://github.com/azurecosmosdb/mcptoolkit)) lets AI agents interact with your database through the MCP standard. It's an open-source MCP server that exposes seven core tools: <!-- Source: build-ai-applications/ai-tools/model-context-protocol-toolkit.md -->

| Tool | Description |
|---|---|
| `list_databases` | List databases in account |
| `list_collections` | List containers in database |
| `get_recent_documents` | Fetch recent 1–20 docs |
| `find_document_by_id` | Point-read by ID |
| `text_search` | Full-text keyword search |
| `vector_search` | Semantic similarity search |
| `get_approximate_schema` | Infer schema from samples |

<!-- Source: build-ai-applications/ai-tools/model-context-protocol-toolkit.md -->

The toolkit deploys as an Azure Container App with Microsoft Entra ID authentication and managed identity for Cosmos DB access — no stored credentials. It integrates with Microsoft Foundry, VS Code (via GitHub Copilot), and any MCP-compatible AI agent.

The practical value: you can prompt an AI agent with "Find recent orders in the ecommerce database" and the agent translates that into MCP tool calls against your Cosmos DB, executed securely through the toolkit. As of this writing, the toolkit is effectively **read-only** — the seven listed tools provide query, search, and schema discovery capabilities, but no write operations. <!-- Inferred from the listed tool set in build-ai-applications/ai-tools/model-context-protocol-toolkit.md; not explicitly stated as a permanent constraint -->

## Azure SRE Agent (Preview)

The **Azure SRE Agent** for Cosmos DB is an AI-powered diagnostic tool that helps you troubleshoot operational issues. It combines AI with deep knowledge of Cosmos DB internals to provide automated diagnostics, actionable insights from diagnostic logs, and best-practices recommendations aligned with the Azure Well-Architected Framework. <!-- Source: build-ai-applications/ai-tools/site-reliability-engineering-agent.md -->

Use cases include performance troubleshooting (high latency, throughput optimization, indexing problems), connectivity issues (authentication errors, regional failover scenarios), and schema design guidance. <!-- Source: build-ai-applications/ai-tools/site-reliability-engineering-agent.md -->

The preview is currently limited to Sweden Central, East US 2, and Australia East regions, with English-language support only. Billing is based on Azure Agent Units (AAUs). <!-- Source: build-ai-applications/ai-tools/site-reliability-engineering-agent.md -->

## AI Coding Assistants: The Agent Kit

The **Azure Cosmos DB Agent Kit** ([AzureCosmosDB/cosmosdb-agent-kit](https://github.com/AzureCosmosDB/cosmosdb-agent-kit)) is an open-source collection of 45+ curated best-practice rules that extend AI coding assistants with expert-level Cosmos DB guidance. It works with **GitHub Copilot**, **Claude Code**, **Gemini CLI**, and any tool that supports the Agent Skills format. <!-- Source: build-ai-applications/ai-tools/agent-kit.md -->

Install with one command:

```bash
npx skills add AzureCosmosDB/cosmosdb-agent-kit
```

Once installed, the skill activates automatically when you're working on Cosmos DB code. Ask your AI assistant to review your data model, optimize a query, or choose a partition key, and it applies production-tested Cosmos DB patterns to its suggestions. The rules cover:

- Data modeling
- Partition key design
- Query optimization
- SDK best practices
- Indexing strategies
- Throughput management
- Global distribution
- Monitoring

<!-- Source: build-ai-applications/ai-tools/agent-kit.md -->

This is a read-only guidance tool — it teaches your AI assistant best practices but doesn't execute operations on your database.

Chapter 26 picks up where the multi-tenant discussion started here, diving deep into tenant isolation patterns, throughput sharing strategies, and fleet management at scale.
