# Preface

## Who This Book Is For

You're a developer who wants to build on Azure Cosmos DB's NoSQL API. You know at least one programming language (examples use C#, Python, and JavaScript), you've worked with databases before, and you're comfortable with basic cloud concepts.

No prior Cosmos DB experience required. We start from zero and build to production-ready.

## How This Book Is Organized

Nine parts, each building on the last:

- **Part I: Foundations** (Ch 1–3) — What Cosmos DB is, core concepts, first working code.
- **Part II: Data Modeling and Partitioning** (Ch 4–6) — Document design, partition keys, advanced patterns.
- **Part III: Working with Data** (Ch 7–9) — SDKs, the query language, and indexing policies.
- **Part IV: Throughput, Scaling, and Cost** (Ch 10–11) — Request Units, capacity models, cost control.
- **Part V: Global Distribution and Consistency** (Ch 12–13) — Multi-region replication and consistency levels.
- **Part VI: Server-Side Programming and Event-Driven Patterns** (Ch 14–16) — Stored procedures, change feed, transactions.
- **Part VII: Security, Monitoring, and Operations** (Ch 17–20) — Security, observability, backup, CI/CD.
- **Part VIII: Integration and Ecosystem** (Ch 21–24) — Advanced SDK patterns, Azure integrations, migration, testing.
- **Part IX: Advanced Topics** (Ch 25–28) — Vector search and AI, multi-tenancy, performance tuning, capstone.

The **Appendices** are quick-reference tables: CLI commands, query syntax, consistency levels, pricing, and service limits.

## How to Read It

New to Cosmos DB? Read Parts I and II in order — they build on each other. After that, jump to whatever your project needs. Each chapter stands on its own, with cross-references where topics connect.

Already using Cosmos DB? Skip to Parts VI–IX.

## How This Book Was Written

Every factual claim in this book was verified against the official Microsoft Learn documentation for Azure Cosmos DB. Where the docs explain *what*, this book explains *why* and *when* — curating the material into a learning arc, sequencing it so each chapter builds on the last, and adding the practitioner perspective that reference documentation can't provide.

The result is a book grounded in the same source of truth you'd consult on the job, retold in a format fit for reading cover to cover. If a number, limit, or behavior appears in these pages, it traces back to the docs. Where opinions appear — and they do — they're clearly the author's, informed by real-world experience building on the platform.

Some sections cover features that are in **preview** at the time of writing. They're included deliberately — preview features often signal where the platform is heading, and understanding them early gives you a head start. Where a feature is in preview, the text says so. Because this book is published digitally, it can be revised at any time; as preview features reach general availability (or change shape), updated editions will reflect the current state of the service.

## Conventions

- **Code**: primarily C# (.NET SDK v3), with Python and JavaScript where noted.
- **Sample data**: code examples use the `cosmicworks` database and `products` container from the official Microsoft quickstarts — a fictional retail store with categories, quantities, and prices. Chapter 3 walks you through seeding your account with this dataset. The data generators are open source at [AzureCosmosDB/CosmicWorks](https://github.com/AzureCosmosDB/CosmicWorks) and [Azure-Samples/cosmicworks](https://github.com/Azure-Samples/cosmicworks).
- **Queries**: Cosmos DB NoSQL query language (SQL-like, operates on JSON).
- **CLI**: bash syntax; PowerShell equivalents in Appendix A.
- All service limits and behaviors verified against official Microsoft documentation as of early 2026.

## Source Code and Errata

Code examples are on GitHub. For errata, updates, and discussion, visit the book's repository.

Let's get started.
