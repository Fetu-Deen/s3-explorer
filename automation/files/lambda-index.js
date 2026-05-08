// =============================================================================
// CloudVault — Lambda Thumbnail Generator
// =============================================================================
// Triggered automatically by S3 every time a file is uploaded (PUT event)
//
// What it does:
//   1. Receives the S3 event (bucket name + file key)
//   2. Skips if it's already a thumbnail (prevents infinite loop)
//   3. Skips if it's not an image file
//   4. Downloads the original image from S3
//   5. Resizes it to 200x200 using sharp
//   6. Uploads the thumbnail back to S3 under thumbnails/{original_key}
//   7. Logs success to CloudWatch
//
// Trigger:   S3 PUT event on cloudvault-files-* bucket
// Runtime:   Node.js 20.x
// Memory:    512 MB
// Timeout:   30 seconds
// =============================================================================

const {
  S3Client,
  GetObjectCommand,
  PutObjectCommand,
} = require("@aws-sdk/client-s3");
const sharp = require("sharp");

// S3 client — Lambda gets credentials automatically from its IAM role
// No need for access keys here (unlike the Express server)
const s3 = new S3Client({ region: "us-east-1" });

// Supported image extensions for thumbnail generation
const IMAGE_EXTENSIONS = ["jpg", "jpeg", "png", "gif", "webp"];

exports.handler = async (event) => {
  // ── Extract bucket and key from the S3 event ───────────────────────────────
  const record = event.Records[0];
  const bucket = record.s3.bucket.name;

  // Decode the key — S3 encodes spaces as + and special chars as %XX
  const key = decodeURIComponent(record.s3.object.key.replace(/\+/g, " "));

  console.log(`Processing: s3://${bucket}/${key}`);

  // ── Guard 1: Skip if already a thumbnail ──────────────────────────────────
  // Without this check, uploading a thumbnail would trigger another Lambda
  // which would create a thumbnail of a thumbnail — infinite loop
  if (key.startsWith("thumbnails/")) {
    console.log("Skipping — already a thumbnail");
    return;
  }

  // ── Guard 2: Skip non-image files ─────────────────────────────────────────
  const ext = key.split(".").pop().toLowerCase();
  if (!IMAGE_EXTENSIONS.includes(ext)) {
    console.log(`Skipping — not an image (extension: .${ext})`);
    return;
  }

  // ── Step 1: Download original image from S3 ───────────────────────────────
  const getRes = await s3.send(
    new GetObjectCommand({ Bucket: bucket, Key: key })
  );

  // Stream the response body into a buffer
  const chunks = [];
  for await (const chunk of getRes.Body) {
    chunks.push(chunk);
  }
  const buffer = Buffer.concat(chunks);

  // ── Step 2: Resize to 200x200 using sharp ────────────────────────────────
  // fit: "cover" — crops to fill the box (like CSS object-fit: cover)
  // This ensures the thumbnail is always exactly 200x200
  const thumbnail = await sharp(buffer)
    .resize(200, 200, { fit: "cover" })
    .toBuffer();

  // ── Step 3: Upload thumbnail to thumbnails/ folder in same bucket ─────────
  const thumbKey = `thumbnails/${key}`;
  const contentType = ext === "jpg" ? "image/jpeg" : `image/${ext}`;

  await s3.send(
    new PutObjectCommand({
      Bucket: bucket,
      Key: thumbKey,
      Body: thumbnail,
      ContentType: contentType,
    })
  );

  console.log(`Thumbnail created: s3://${bucket}/${thumbKey}`);
};
