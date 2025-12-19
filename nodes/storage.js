const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

// Storage directory for hash-addressed content
const STORAGE_DIR = path.join(__dirname, 'storage-data');

// Ensure storage directory exists
function ensureStorageDir() {
  if (!fs.existsSync(STORAGE_DIR)) {
    fs.mkdirSync(STORAGE_DIR, { recursive: true });
  }
}

/**
 * Calculate SHA256 hash of content
 * @param {string|Buffer} content - The content to hash
 * @returns {string} - Hex-encoded SHA256 hash
 */
function calculateHash(content) {
  return crypto.createHash('sha256').update(content).digest('hex');
}

/**
 * Store content and return its hash
 * @param {string|Buffer} content - The content to store
 * @returns {string} - The SHA256 hash of the stored content
 */
function storeContent(content) {
  ensureStorageDir();

  const hash = calculateHash(content);
  const filePath = path.join(STORAGE_DIR, hash);

  // Only write if file doesn't already exist (content-addressable)
  if (!fs.existsSync(filePath)) {
    fs.writeFileSync(filePath, content);
  }

  return hash;
}

/**
 * Retrieve content by its hash
 * @param {string} hash - The SHA256 hash of the content
 * @returns {Buffer|null} - The content as Buffer, or null if not found
 */
function getContent(hash) {
  ensureStorageDir();

  // Validate hash format (64 hex characters)
  if (!/^[a-f0-9]{64}$/i.test(hash)) {
    return null;
  }

  const filePath = path.join(STORAGE_DIR, hash.toLowerCase());

  if (!fs.existsSync(filePath)) {
    return null;
  }

  return fs.readFileSync(filePath);
}

/**
 * Check if content exists by hash
 * @param {string} hash - The SHA256 hash to check
 * @returns {boolean} - True if content exists
 */
function hasContent(hash) {
  ensureStorageDir();

  if (!/^[a-f0-9]{64}$/i.test(hash)) {
    return false;
  }

  const filePath = path.join(STORAGE_DIR, hash.toLowerCase());
  return fs.existsSync(filePath);
}

module.exports = {
  calculateHash,
  storeContent,
  getContent,
  hasContent
};
