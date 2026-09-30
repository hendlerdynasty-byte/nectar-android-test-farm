# Ephemeral encrypted transport proof

This alternative requires no new repository secret or paid capacity. Standard
ubuntu-24.04 public GitHub runners were verified free against official pricing
on 2026-09-30. No app repository is cloned by this workflow.

The worker creates an ephemeral RSA-3072 key in RAM. Only its public key is
published in a per-request temporary transport branch. The caller seals the APK
and request with AES-256-GCM, binding request identity and input/output direction;
the AES key is wrapped with RSA-OAEP-SHA256. Only authenticated ciphertext travels
through the public transport branch. Plaintext APK, request and runtime evidence
exist solely in runner temporary storage and the authorized private workspace.
Results are encrypted to a separate caller-held key, never the input worker key.

The caller deletes the temporary ref after receiving evidence. Unreachable Git
objects may retain ciphertext; this is explicitly cryptographic erasure, not a
claim of guaranteed physical deletion. The runner private key is never persisted
or exported and is destroyed when the runner terminates. There is no persistent
ability to decrypt input ciphertext. No plaintext APK or product source is ever
public. Treat this as a confidentiality proof, not certification of provider
physical erasure. Never place private source archives into this protocol.

contents:write is narrowly needed to publish ephemeral public keys/encrypted
responses in the generic infra repository. The workflow has no PR trigger,
receives no app secrets, and checks UUIDs and artifact identity fail-closed.
This supplement does not claim STANDARD/RELEASE support or Firebase completion.
