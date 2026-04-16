# Publishing TENEX Agent Definitions with `nak`

This skill teaches you how to publish kind 4199 agent definition events using the `nak` CLI.

## Event Structure

Kind 4199 events define AI agents in the TENEX/Nostr ecosystem. The event structure:

| Field | Description |
|-------|-------------|
| `kind` | `4199` |
| `content` | Extended markdown description (optional) |
| `d` tag | **Required.** Slug/identifier for the agent (enables versioning) |
| `title` tag | **Required.** Human-readable agent name |
| `role` tag | **Required.** The agent's expertise and personality |
| `description` tag | One-liner summary of agent purpose |
| `instructions` tag | Detailed operational guidelines (system prompt content) |
| `use-criteria` tag | When to select/use this agent |
| `category` tag | Classification: `principal`, `orchestrator`, `worker`, `reviewer`, `domain-expert`, `generalist` |
| `ver` tag | Version number (integer, defaults to 1) |

### Optional Reference Tags

| Tag | Format | Description |
|-----|--------|-------------|
| `e` tag | `["e", "<event-id>", "<relay>", "file"]` | References kind 1063 file metadata events |
| `e` tag | `["e", "<event-id>", "<relay>", "fork"]` | References source agent this was forked from |
| `skill` tag | `["skill", "<event-id>"]` | References kind 4202 skill events to include |

## Basic Example

```bash
nak event -k 4199 \
  --tag d=my-assistant \
  --tag title="My Assistant" \
  --tag role="General purpose assistant" \
  --tag description="A helpful AI assistant for everyday tasks" \
  --tag instructions="You are a helpful assistant. Be concise and accurate." \
  --tag use-criteria="Use for general questions and tasks" \
  --tag category=generalist \
  --tag ver=1 \
  --content "## My Assistant

A general-purpose AI assistant designed to help with everyday tasks.

### Capabilities
- Answer questions
- Help with writing
- Provide explanations" \
  --sec <your-nsec> \
  wss://relay.example.com
```

## Minimal Example

The bare minimum required tags:

```bash
nak event -k 4199 \
  --tag d=minimal-agent \
  --tag title="Minimal Agent" \
  --tag role="Basic assistant" \
  --sec <your-nsec> \
  wss://relay.example.com
```

## Domain Expert Example

```bash
nak event -k 4199 \
  --tag d=typescript-expert \
  --tag title="TypeScript Expert" \
  --tag role="Senior TypeScript developer with deep knowledge of type systems, generics, and best practices" \
  --tag description="Expert in TypeScript development and type-safe programming" \
  --tag instructions="You are a TypeScript expert. Provide type-safe solutions, explain type inference, and follow strict TypeScript best practices. Always prefer explicit types over 'any'." \
  --tag use-criteria="Use when working with TypeScript code, type errors, or designing type-safe APIs" \
  --tag category=domain-expert \
  --tag ver=1 \
  --sec <your-nsec> \
  wss://relay.example.com
```

## Orchestrator Example

```bash
nak event -k 4199 \
  --tag d=project-manager \
  --tag title="Project Manager" \
  --tag role="Strategic project manager who coordinates work across multiple agents" \
  --tag description="Orchestrates multi-agent workflows and ensures project coherence" \
  --tag instructions="You coordinate work across specialized agents. Break down tasks, delegate appropriately, and synthesize results. Never do work that should be delegated to specialists." \
  --tag use-criteria="Use as the entry point for complex multi-step tasks requiring coordination" \
  --tag category=orchestrator \
  --tag ver=1 \
  --sec <your-nsec> \
  wss://relay.example.com
```

## Versioning an Agent

The `d` tag (slug) enables versioning. Same author + same `d` tag = same agent, different versions:

```bash
# Version 2 of the same agent
nak event -k 4199 \
  --tag d=my-assistant \
  --tag title="My Assistant" \
  --tag role="Improved general purpose assistant" \
  --tag ver=2 \
  --tag instructions="Updated instructions for v2..." \
  --sec <your-nsec> \
  wss://relay.example.com
```

## Forking an Agent

Reference the source agent with an `e` tag using the `fork` marker:

```bash
nak event -k 4199 \
  --tag d=my-forked-assistant \
  --tag title="My Forked Assistant" \
  --tag role="Customized assistant based on another" \
  --tag e=<source-event-id>,,fork \
  --sec <your-nsec> \
  wss://relay.example.com
```

## Attaching Skills

Reference kind 4202 skill events:

```bash
nak event -k 4199 \
  --tag d=skilled-agent \
  --tag title="Skilled Agent" \
  --tag role="Agent with specific skills" \
  --tag skill=<skill-event-id-1> \
  --tag skill=<skill-event-id-2> \
  --sec <your-nsec> \
  wss://relay.example.com
```

## Attaching Files

Reference kind 1063 file metadata events with the `file` marker:

```bash
nak event -k 4199 \
  --tag d=agent-with-files \
  --tag title="Agent With Files" \
  --tag role="Agent bundled with scripts" \
  --tag e=<file-metadata-event-id>,,file \
  --sec <your-nsec> \
  wss://relay.example.com
```

## Best Practices

1. **Slug naming**: Use lowercase, hyphenated slugs (`my-agent` not `MyAgent`)

2. **Role vs Instructions**: 
   - `role`: WHO the agent is (personality, expertise)
   - `instructions`: HOW the agent should behave (rules, guidelines)

3. **Use criteria**: Write this from the perspective of someone choosing which agent to use

4. **Categories**: Choose the most specific category:
   - `principal` — Entry point agents that interact directly with users
   - `orchestrator` — Coordinates other agents
   - `worker` — Executes specific tasks
   - `reviewer` — Reviews/validates work
   - `domain-expert` — Deep expertise in a specific domain
   - `generalist` — General-purpose assistant

5. **Version incrementing**: Always increment `ver` when publishing updates

6. **Content field**: Use for longer markdown descriptions; keep tags concise

## Common Pitfalls

1. **Missing `d` tag**: Without it, you can't version your agent or create replaceable events

2. **Overly long instructions in tags**: Keep tag values concise; use `content` for extended documentation

3. **Forgetting `--sec`**: The event must be signed with your nsec

4. **Wrong relay**: Ensure you publish to relays your TENEX instance monitors

## Querying Existing Agents

Find agent definitions by author:

```bash
nak req -k 4199 -a <author-pubkey> wss://relay.example.com
```

Find a specific agent by slug:

```bash
nak req -k 4199 -a <author-pubkey> -d <slug> wss://relay.example.com
```
