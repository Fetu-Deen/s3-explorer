// =============================================================================
// CloudVault — Express API Server
// =============================================================================
// This file is deployed to EC2 automatically by setup.sh
// It acts as the middleman between the React frontend and AWS services (S3 + RDS)
//
// Endpoints:
//   GET    /api/files          — list all files (metadata from RDS)
//   POST   /api/upload         — upload file to S3 + save metadata to RDS
//   GET    /api/files/:id/view — generate pre-signed S3 URL (expires 60s)
//   GET    /api/files/:id/thumbnail — pre-signed URL for thumbnail (expires 300s)
//   DELETE /api/files/:id      — delete from S3 + remove from RDS
// =============================================================================

require("dotenv").config();
const express = require("express");
const cors = require("cors");
const multer = require("multer");
const mysql = require("mysql2/promise");
const {
  S3Client,
  PutObjectCommand,
  DeleteObjectCommand,
  GetObjectCommand,
} = require("@aws-sdk/client-s3");
const { getSignedUrl } = require("@aws-sdk/s3-request-presigner");

const app = express();
app.use(cors());
app.use(express.json());

// ── S3 client — credentials auto-injected from EC2 instance profile (IAM role)
const s3 = new S3Client({
  region: process.env.AWS_REGION,
});

// ── multer — holds uploaded file in memory before sending to S3 ─────────────
const upload = multer({ storage: multer.memoryStorage() });

// ── RDS connection factory — creates a fresh connection per request ──────────
async function getDb() {
  return mysql.createConnection({
    host: process.env.DB_HOST,
    user: process.env.DB_USER,
    password: process.env.DB_PASS,
    database: process.env.DB_NAME,
  });
}

// ── Create files table if it doesn't exist yet ──────────────────────────────
async function initDb() {
  const db = await getDb();
  await db.execute(`
    CREATE TABLE IF NOT EXISTS files (
      id           INT AUTO_INCREMENT PRIMARY KEY,
      file_name    VARCHAR(255)  NOT NULL,
      s3_key       VARCHAR(255)  NOT NULL,
      file_size    BIGINT        NOT NULL,
      file_type    VARCHAR(100),
      description  TEXT,
      uploaded_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
  `);
  await db.end();
  console.log("Database initialized");
}

// ── GET /api/files — return all file records ordered by newest first ─────────
app.get("/api/files", async (req, res) => {
  try {
    const db = await getDb();
    const [rows] = await db.execute(
      "SELECT * FROM files ORDER BY uploaded_at DESC"
    );
    await db.end();
    res.json(rows);
  } catch (err) {
    res.json({ error: err.message });
  }
});

// ── POST /api/upload — receive file, push to S3, save metadata to RDS ───────
app.post("/api/upload", upload.single("file"), async (req, res) => {
  try {
    const file = req.file;
    const description = req.body.description || "";

    // Prefix with timestamp to avoid collisions for same-name files
    const s3Key = `${Date.now()}-${file.originalname}`;

    // Step 1 — upload bytes to S3
    await s3.send(
      new PutObjectCommand({
        Bucket: process.env.S3_BUCKET,
        Key: s3Key,
        Body: file.buffer,
        ContentType: file.mimetype,
      })
    );

    // Step 2 — save metadata to RDS (only after S3 succeeds)
    const db = await getDb();
    await db.execute(
      "INSERT INTO files (file_name, s3_key, file_size, file_type, description) VALUES (?, ?, ?, ?, ?)",
      [file.originalname, s3Key, file.size, file.mimetype, description]
    );
    await db.end();

    res.json({ success: true });
  } catch (err) {
    res.json({ error: err.message });
  }
});

// ── GET /api/files/:id/view — generate a 60-second pre-signed URL ───────────
app.get("/api/files/:id/view", async (req, res) => {
  try {
    const db = await getDb();
    const [rows] = await db.execute("SELECT * FROM files WHERE id = ?", [
      req.params.id,
    ]);
    await db.end();

    if (rows.length === 0) return res.json({ error: "File not found" });

    const url = await getSignedUrl(
      s3,
      new GetObjectCommand({
        Bucket: process.env.S3_BUCKET,
        Key: rows[0].s3_key,
      }),
      { expiresIn: 60 }
    );

    res.json({ url });
  } catch (err) {
    res.json({ error: err.message });
  }
});

// ── GET /api/files/:id/thumbnail — pre-signed URL for Lambda thumbnail ───────
app.get("/api/files/:id/thumbnail", async (req, res) => {
  try {
    const db = await getDb();
    const [rows] = await db.execute("SELECT * FROM files WHERE id = ?", [
      req.params.id,
    ]);
    await db.end();

    if (rows.length === 0) return res.json({ error: "File not found" });

    // Lambda saves thumbnails under thumbnails/{original_s3_key}
    const thumbKey = `thumbnails/${rows[0].s3_key}`;

    const url = await getSignedUrl(
      s3,
      new GetObjectCommand({
        Bucket: process.env.S3_BUCKET,
        Key: thumbKey,
      }),
      { expiresIn: 300 }
    );

    res.json({ url });
  } catch (err) {
    res.json({ error: err.message });
  }
});

// ── DELETE /api/files/:id — remove from S3 then delete RDS record ───────────
app.delete("/api/files/:id", async (req, res) => {
  try {
    const db = await getDb();
    const [rows] = await db.execute("SELECT * FROM files WHERE id = ?", [
      req.params.id,
    ]);

    if (rows.length === 0) {
      await db.end();
      return res.json({ error: "File not found" });
    }

    // Step 1 — delete from S3
    await s3.send(
      new DeleteObjectCommand({
        Bucket: process.env.S3_BUCKET,
        Key: rows[0].s3_key,
      })
    );

    // Step 2 — delete from RDS
    await db.execute("DELETE FROM files WHERE id = ?", [req.params.id]);
    await db.end();

    res.json({ success: true });
  } catch (err) {
    res.json({ error: err.message });
  }
});

// ── Start server ─────────────────────────────────────────────────────────────
initDb().then(() => {
  app.listen(process.env.PORT || 4000, () => {
    console.log(`CloudVault server running on port ${process.env.PORT || 4000}`);
  });
});
