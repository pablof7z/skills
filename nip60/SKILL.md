# NIP-60 Cashu Wallet & NIP-61 Nutzaps - Complete Implementation Guide

## Overview

This skill provides comprehensive knowledge for building Cashu wallets on Nostr using `@nostr-dev-kit/wallet`. It covers NIP-60 (Cashu Wallets) and NIP-61 (Nutzaps) specifications and their NDK implementations.

## NIP References

- **NIP-60 (Cashu Wallets)**: https://github.com/nostr-protocol/nips/blob/master/60.md
- **NIP-61 (Nutzaps)**: https://github.com/nostr-protocol/nips/blob/master/61.md

---

## Event Kinds Reference

| Kind | Constant | Description | Encryption |
|------|----------|-------------|------------|
| 375 | `NDKKind.CashuWalletBackup` | Wallet private key backup | NIP-44 encrypted to self |
| 7373 | `NDKKind.CashuReserve` | Reserved proofs for pending operations | NIP-44 encrypted |
| 7374 | `NDKKind.CashuQuote` | Pending mint quote (deposit in progress) | NIP-44 encrypted |
| 7375 | `NDKKind.CashuToken` | Stored Cashu proofs (the actual tokens) | NIP-44 encrypted |
| 7376 | `NDKKind.CashuWalletTx` | Transaction history record | NIP-44 encrypted |
| 10019 | `NDKKind.CashuMintList` | Public mint preferences for receiving nutzaps | **NOT encrypted** |
| 17375 | `NDKKind.CashuWallet` | Wallet configuration (mints, privkeys, relays) | NIP-44 encrypted |
| 9321 | `NDKKind.Nutzap` | Nutzap event (sending Cashu tokens to someone) | **NOT encrypted** |

---

## Installation

```bash
npm install @nostr-dev-kit/ndk @nostr-dev-kit/wallet
# or
pnpm add @nostr-dev-kit/ndk @nostr-dev-kit/wallet
# or
bun add @nostr-dev-kit/ndk @nostr-dev-kit/wallet
```

---

## Core Concepts

### What is NIP-60?

NIP-60 defines a standard for storing Cashu wallet state on Nostr relays. Key principles:

1. **Wallet Configuration (kind 17375)**: Encrypted event containing mint URLs, private keys for P2PK, and relay preferences
2. **Token Storage (kind 7375)**: Encrypted events containing Cashu proofs (actual ecash)
3. **Transaction History (kind 7376)**: Encrypted events recording wallet transactions
4. **Backup (kind 375)**: Encrypted backup of wallet private keys

### What is NIP-61?

NIP-61 defines "Nutzaps" - a way to send Cashu tokens via Nostr events:

1. **Mint List (kind 10019)**: Public event advertising which mints you accept and your P2PK pubkey
2. **Nutzap (kind 9321)**: Public event containing P2PK-locked Cashu proofs sent to a recipient

### P2PK (Pay-to-Public-Key)

Cashu proofs can be locked to a public key. Only the holder of the corresponding private key can redeem them. This is how nutzaps work - tokens are locked to the recipient's advertised P2PK.

---

## Complete Wallet Implementation

### Step 1: Initialize NDK

```typescript
import NDK, { NDKPrivateKeySigner } from "@nostr-dev-kit/ndk";

const ndk = new NDK({
    explicitRelayUrls: [
        "wss://relay.damus.io",
        "wss://relay.primal.net",
        "wss://nos.lol"
    ],
    signer: new NDKPrivateKeySigner("your-nsec-here")
});

await ndk.connect();
```

### Step 2: Create a New Wallet

```typescript
import { NDKCashuWallet } from "@nostr-dev-kit/wallet";

// Create a new wallet with mints and optional relays
const wallet = await NDKCashuWallet.create(
    ndk,
    ["https://mint.minibits.cash/Bitcoin"],  // Mint URLs
    ["wss://relay.damus.io"]                  // Optional: dedicated wallet relays
);

// The create() method:
// 1. Generates a new private key for P2PK
// 2. Publishes the wallet event (kind 17375)
// 3. Creates and publishes a backup (kind 375)
```

### Step 3: Load an Existing Wallet

```typescript
import { NDKCashuWallet, NDKKind } from "@nostr-dev-kit/wallet";

// Fetch the wallet event
const walletEvent = await ndk.fetchEvent({
    kinds: [NDKKind.CashuWallet],
    authors: [user.pubkey]
});

if (walletEvent) {
    const wallet = await NDKCashuWallet.from(walletEvent);
    
    // Start monitoring for token events
    await wallet.start();
    
    // Wait for ready state
    wallet.on("ready", () => {
        console.log("Wallet loaded, balance:", wallet.balance?.amount);
    });
}
```

### Step 4: Publish Mint List for Nutzaps

```typescript
// This publishes kind 10019 so others know how to send you nutzaps
await wallet.publishMintList();

// The mint list contains:
// - Your accepted mints (mint tags)
// - Your nutzap inbox relays (relay tags)  
// - Your P2PK pubkey (pubkey tag)
```

---

## Wallet Operations

### Depositing (Lightning → Cashu)

```typescript
// Create a deposit for 1000 sats
const deposit = wallet.deposit(1000, "https://mint.minibits.cash/Bitcoin");

// Listen for events
deposit.on("success", (token) => {
    console.log("Deposit successful! Token event:", token.id);
    console.log("New balance:", wallet.balance?.amount);
});

deposit.on("error", (error) => {
    console.error("Deposit failed:", error);
});

// Start the deposit - returns a Lightning invoice (bolt11)
const bolt11 = await deposit.start();
console.log("Pay this invoice:", bolt11);

// The deposit will automatically poll for payment
// Once paid, the "success" event fires
```

### Sending Cashu Tokens (Create Shareable Token)

```typescript
// Create an encoded Cashu token that can be shared
const token = await wallet.send(1000, "Coffee payment");
console.log("Share this token:", token);
// Output: cashuAeyJ0b2tlbiI6W3sicHJvb...
```

### Receiving Cashu Tokens

```typescript
// Receive a Cashu token string
const tokenString = "cashuAeyJ0b2tlbiI6W3sicHJvb...";
const tokenEvent = await wallet.receiveToken(tokenString, "Payment received");
console.log("Token received, new balance:", wallet.balance?.amount);
```

### Paying Lightning Invoices

```typescript
import { LnPaymentInfo } from "@nostr-dev-kit/ndk";

const payment: LnPaymentInfo = {
    pr: "lnbc1000n1p..."  // bolt11 invoice
};

const confirmation = await wallet.lnPay({ ...payment });

if (confirmation) {
    console.log("Payment successful!");
    console.log("Preimage:", confirmation.preimage);
}
```

### Paying with Cashu (P2PK Transfer)

```typescript
import { CashuPaymentInfo, NDKZapDetails } from "@nostr-dev-kit/ndk";

const payment: NDKZapDetails<CashuPaymentInfo> = {
    amount: 1000,  // sats
    unit: "sat",
    mints: ["https://mint.minibits.cash/Bitcoin"],  // acceptable mints
    p2pk: "recipient-p2pk-pubkey"  // recipient's P2PK from their mint list
};

const confirmation = await wallet.cashuPay(payment);

if (confirmation) {
    console.log("Cashu payment sent!");
    console.log("Proofs:", confirmation.proofs);
}
```

### Minting Raw Proofs

```typescript
// Create proofs of specific denominations
const result = await wallet.mintNuts([100, 200, 500]);  // 800 total sats

if (result) {
    console.log("Minted proofs:", result.send);
    // These are raw Proof objects, not yet encoded as a token
}
```

---

## Wallet State & Balance

### Checking Balance

```typescript
// Total available balance
const balance = wallet.balance?.amount;
console.log("Total balance:", balance, "sats");

// Balance per mint
const mintBalances = wallet.mintBalances;
for (const [mint, balance] of Object.entries(mintBalances)) {
    console.log(`${mint}: ${balance} sats`);
}

// Check specific mint balance
const mintBalance = wallet.mintBalance("https://mint.example.com");
```

### Finding Mints with Sufficient Balance

```typescript
// Get mints that have at least 5000 sats available
const mints = wallet.getMintsWithBalance(5000);
console.log("Mints with 5000+ sats:", mints);
```

### Accessing Proofs

```typescript
// Get all proofs for a specific mint
const proofs = await wallet.state.getProofs({ 
    mint: "https://mint.example.com",
    onlyAvailable: true  // exclude reserved proofs
});

// Get proofs across all mints
const allProofs = await wallet.state.getProofs({ onlyAvailable: true });
```

---

## Wallet Events

```typescript
// Wallet is ready and synced
wallet.on("ready", () => {
    console.log("Wallet ready!");
});

// Balance changed
wallet.on("balance_updated", () => {
    console.log("New balance:", wallet.balance?.amount);
});

// Status changed
wallet.on("status_changed", (status) => {
    // NDKWalletStatus: INITIAL, LOADING, READY
    console.log("Status:", status);
});

// Warning (e.g., duplicate token detected)
wallet.on("warning", ({ msg, event, relays }) => {
    console.warn("Wallet warning:", msg);
});
```

---

## Nutzap Monitor (Receiving Nutzaps)

The `NDKNutzapMonitor` automatically detects and redeems incoming nutzaps.

### Basic Setup

```typescript
import { NDKNutzapMonitor, NDKCashuWallet } from "@nostr-dev-kit/wallet";
import { NDKUser } from "@nostr-dev-kit/ndk";

// Create user and wallet
const user = ndk.activeUser!;
const wallet = await loadOrCreateWallet();  // your wallet loading logic

// Create monitor
const monitor = new NDKNutzapMonitor(ndk, user, {
    mintList: wallet.mintList,  // optional: your mint list for validation
    store: myNutzapStore        // optional: persistence for nutzap states
});

// Assign wallet for redemption
monitor.wallet = wallet;

// Start monitoring
await monitor.start({});
```

### Monitor Events

```typescript
// New nutzap seen
monitor.on("seen", (nutzap) => {
    console.log("New nutzap from:", nutzap.pubkey);
    console.log("Amount:", nutzap.amount, "sats");
});

// Nutzap successfully redeemed
monitor.on("redeemed", (nutzaps, amount) => {
    console.log(`Redeemed ${nutzaps.length} nutzaps for ${amount} sats`);
});

// Nutzap state changed
monitor.on("state_changed", (nutzapId, status) => {
    // NdkNutzapStatus: INITIAL, PROCESSING, REDEEMED, SPENT, 
    //                  MISSING_PRIVKEY, INVALID_NUTZAP, PERMANENT_ERROR
    console.log(`Nutzap ${nutzapId} state: ${status}`);
});

// Failed to redeem
monitor.on("failed", (nutzap, error) => {
    console.error("Failed to redeem nutzap:", error);
});

// Nutzap from unknown mint
monitor.on("seen_in_unknown_mint", (nutzap) => {
    console.warn("Nutzap from mint not in your list:", nutzap.mint);
});
```

### Nutzap State Persistence

Implement `NDKNutzapMonitorStore` for persistence:

```typescript
import { NDKNutzapMonitorStore, NDKNutzapState } from "@nostr-dev-kit/wallet";

const store: NDKNutzapMonitorStore = {
    async getAllNutzaps(): Promise<Map<string, NDKNutzapState>> {
        // Load from your database
        const states = await db.loadNutzapStates();
        return new Map(states);
    },
    
    async setNutzapState(id: string, state: Partial<NDKNutzapState>): Promise<void> {
        // Save to your database
        await db.updateNutzapState(id, state);
    }
};

const monitor = new NDKNutzapMonitor(ndk, user, { store });
```

### Private Key Management

The monitor automatically loads private keys from:
1. The assigned wallet's privkeys
2. The NDK signer (if it's a private key signer)
3. Backup events (kind 375) and wallet config events (kind 17375)

```typescript
// Manually add a private key if needed
import { NDKPrivateKeySigner } from "@nostr-dev-kit/ndk";

const signer = new NDKPrivateKeySigner("nsec...");
await monitor.addPrivkey(signer);
```

---

## Sending Nutzaps

To send a nutzap, you need the recipient's mint list:

```typescript
import { NDKCashuMintList, NDKKind, NDKNutzap } from "@nostr-dev-kit/ndk";

// Fetch recipient's mint list
const mintListEvent = await ndk.fetchEvent({
    kinds: [NDKKind.CashuMintList],
    authors: [recipientPubkey]
});

if (!mintListEvent) {
    throw new Error("Recipient has no mint list - cannot send nutzap");
}

const mintList = NDKCashuMintList.from(mintListEvent);

// Check if we share any mints
const sharedMints = wallet.mints.filter(m => mintList.mints.includes(m));
if (sharedMints.length === 0) {
    throw new Error("No shared mints with recipient");
}

// Create proofs locked to recipient's P2PK
const payment = await wallet.cashuPay({
    amount: 1000,
    unit: "sat",
    mints: sharedMints,
    p2pk: mintList.p2pk  // recipient's P2PK pubkey
});

// Create and publish nutzap event
const nutzap = new NDKNutzap(ndk);
nurzap.proofs = payment.proofs;
nurzap.mint = payment.mint;
nurzap.tags.push(["p", recipientPubkey]);  // tag the recipient

// Optionally reference the event being zapped
// nutzap.tags.push(["e", eventId]);

await nutzap.publish(mintList.relaySet);  // publish to recipient's nutzap relays
```

---

## Wallet Configuration Management

### Updating Mints

```typescript
// Add a mint
wallet.mints = [...wallet.mints, "https://new-mint.example.com"];
await wallet.publish();

// Remove a mint
wallet.mints = wallet.mints.filter(m => m !== "https://old-mint.com");
await wallet.publish();

// Or use update() for atomic changes
await wallet.update({
    mints: ["https://mint1.com", "https://mint2.com"],
    relays: ["wss://relay1.com", "wss://relay2.com"]
});
```

### Updating Relays

```typescript
import { NDKRelaySet } from "@nostr-dev-kit/ndk";

// Set specific relays for wallet events
wallet.relaySet = NDKRelaySet.fromRelayUrls(
    ["wss://relay1.com", "wss://relay2.com"],
    ndk
);
await wallet.publish();

// Clear to use NIP-65 fallback
wallet.relaySet = undefined;
await wallet.publish();
```

### Backup

```typescript
// Create and publish a backup event (kind 375)
const backup = await wallet.backup(true);  // true = publish immediately

// Create without publishing
const backupEvent = await wallet.backup(false);
// ... review or modify ...
await backupEvent.save(wallet.relaySet);
```

---

## Transaction History

### Fetching Transactions

```typescript
const transactions = await wallet.fetchTransactions();

for (const tx of transactions) {
    console.log({
        id: tx.id,
        direction: tx.direction,  // "in" or "out"
        amount: tx.amount,
        timestamp: new Date(tx.timestamp * 1000),
        description: tx.description,
        fee: tx.fee,
        mint: tx.mint
    });
}
```

### Real-time Transaction Updates

```typescript
const unsubscribe = wallet.subscribeTransactions((tx) => {
    console.log("New transaction:", tx);
});

// Later: stop subscription
unsubscribe();
```

---

## Mint Information Caching

For performance, cache mint info and keys:

```typescript
import { createMintCacheCallbacks } from "@nostr-dev-kit/wallet";

// If your cache adapter supports generic caching
if (ndk.cacheAdapter?.getCacheData && ndk.cacheAdapter?.setCacheData) {
    const callbacks = createMintCacheCallbacks(ndk.cacheAdapter);
    
    wallet.onMintInfoNeeded = callbacks.onMintInfoNeeded;
    wallet.onMintInfoLoaded = callbacks.onMintInfoLoaded;
    wallet.onMintKeysNeeded = callbacks.onMintKeysNeeded;
    wallet.onMintKeysLoaded = callbacks.onMintKeysLoaded;
}

// Or implement custom caching
wallet.onMintInfoNeeded = async (mint: string) => {
    return await myCache.get(`mint-info:${mint}`);
};

wallet.onMintInfoLoaded = (mint: string, info: GetInfoResponse) => {
    myCache.set(`mint-info:${mint}`, info);
};
```

---

## Complete Example: Full Wallet App

```typescript
import NDK, { NDKPrivateKeySigner, NDKKind, NDKUser } from "@nostr-dev-kit/ndk";
import { NDKCashuWallet, NDKNutzapMonitor } from "@nostr-dev-kit/wallet";

async function main() {
    // 1. Initialize NDK
    const ndk = new NDK({
        explicitRelayUrls: ["wss://relay.damus.io", "wss://nos.lol"],
        signer: new NDKPrivateKeySigner(process.env.NSEC!)
    });
    await ndk.connect();
    
    const user = await ndk.signer!.user();
    
    // 2. Load or create wallet
    let wallet: NDKCashuWallet;
    
    const existingWallet = await ndk.fetchEvent({
        kinds: [NDKKind.CashuWallet],
        authors: [user.pubkey]
    });
    
    if (existingWallet) {
        wallet = (await NDKCashuWallet.from(existingWallet))!;
        await wallet.start();
    } else {
        wallet = await NDKCashuWallet.create(
            ndk,
            ["https://mint.minibits.cash/Bitcoin"],
            ["wss://relay.damus.io"]
        );
    }
    
    // 3. Publish mint list for receiving nutzaps
    await wallet.publishMintList();
    
    // 4. Start nutzap monitor
    const monitor = new NDKNutzapMonitor(ndk, user, {});
    monitor.wallet = wallet;
    
    monitor.on("redeemed", (nutzaps, amount) => {
        console.log(`Received ${amount} sats via nutzap!`);
    });
    
    await monitor.start({});
    
    // 5. Ready to use
    console.log("Wallet ready!");
    console.log("Balance:", wallet.balance?.amount, "sats");
    console.log("Mints:", wallet.mints);
    console.log("P2PK:", wallet.p2pk);
    
    // Example: Create a deposit
    const deposit = wallet.deposit(1000);
    deposit.on("success", () => console.log("Deposit received!"));
    const invoice = await deposit.start();
    console.log("Pay this invoice:", invoice);
}

main().catch(console.error);
```

---

## Error Handling Best Practices

```typescript
// Wrap operations in try-catch
try {
    await wallet.lnPay({ pr: bolt11 });
} catch (error) {
    if (error.message.includes("insufficient balance")) {
        console.error("Not enough funds");
    } else if (error.message.includes("mint")) {
        console.error("Mint error:", error.message);
    } else {
        console.error("Payment failed:", error);
    }
}

// Handle nutzap redemption errors
monitor.on("failed", (nutzap, error) => {
    if (error.includes("already spent")) {
        // Token was claimed by someone else
    } else if (error.includes("privkey")) {
        // Missing private key for P2PK
    } else {
        // Other error
    }
});
```

---

## Security Considerations

1. **Private Keys**: The wallet generates a separate private key for P2PK. This is stored encrypted in the wallet event (kind 17375) and backed up in kind 375 events.

2. **Encryption**: All sensitive wallet data uses NIP-44 encryption to self. Only kinds 10019 (mint list) and 9321 (nutzap) are public.

3. **Relay Selection**: Use trusted relays for wallet events. Consider using different relays for wallet state vs. regular Nostr activity.

4. **Mint Trust**: Only use mints you trust. The mint can see all transactions and could potentially rug (refuse to honor tokens).

5. **Proof Validation**: Always validate proofs are unspent before accepting. The nutzap monitor handles this automatically.

---

## Troubleshooting

### Wallet Not Loading
- Ensure the user is authenticated (NDK signer is set)
- Check that relays are connected
- Verify kind 17375 event exists for the user

### Nutzaps Not Being Received
- Verify mint list (kind 10019) is published
- Check that P2PK is set correctly in mint list
- Ensure nutzap relays are in your relay set
- Verify you have the private key matching your P2PK

### Balance Not Updating
- Call `wallet.start()` to begin monitoring
- Check for `balance_updated` events
- Verify token events (kind 7375) are being received

### Payment Failures
- Check mint connectivity
- Verify sufficient balance in a shared mint
- For nutzaps: ensure shared mints with recipient
