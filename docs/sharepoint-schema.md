# SharePoint schema

## Status, scope, and fixed architecture

This document is a design specification. It does not report a deployment, a
successful SharePoint connection, or tested tenant behavior.

The exporter uses exactly two SharePoint containers:

1. **Photos** — one document library containing byte-for-byte original image
   and video files.
2. **Photo Metadata** — one SharePoint list containing metadata associated with
   those files.

No additional list, library, hidden storage container, JSON sidecar, or list
attachment is permitted. Immich is read-only. One physical file is stored for
each distinct SHA-256 value; multiple Immich assets may reference that file.

The Photo Metadata list uses only two application record kinds:

- `Asset` — exactly one primary metadata item per Immich asset.
- `MetadataChunk` — optional additional items used only when the complete
  serialized metadata envelope does not fit in the primary item.

Ordinary metadata, including individual EXIF fields, never creates one item per
property. An asset whose metadata fits the primary item occupies exactly one
Photo Metadata list item. Storage failure is represented by the primary Asset
item's `I2SPSyncState`; there is no `Overflow` record kind.

## Conventions

- Internal names are stable ASCII identifiers. Display names may be chosen for
  readability during provisioning.
- Hash values are lowercase hexadecimal SHA-256 strings.
- Date/time columns store UTC when a source value can be normalized reliably.
  Raw source timestamp text is preserved separately in the metadata envelope
  and, for date taken, in `I2SPDateTakenRaw`.
- “Multiple lines text” means plain text: rich text and append-only changes are
  disabled.
- Conditional requirements such as “Asset only” are enforced by the sync
  service, not by SharePoint's column-level `Required` flag, because both record
  kinds share one list.
- The built-in Photo Metadata `Title` field is not authoritative. Provisioning
  should make it optional and omit it from normal views if the tenant permits.

## Photos document library

The Photos library contains original bytes without EXIF edits, transcoding,
timestamp changes, or any other content modification.

| Internal name | SharePoint type | Required | Index/uniqueness | Rules |
| --- | --- | --- | --- | --- |
| `FileLeafRef` | Built-in Name | Yes | Built-in | Deterministic filename based on content identity |
| `I2SPContentSha256` | Single line text, maximum 64 | Yes after upload | Unique and indexed | Identity of the exact original bytes |
| `I2SPSourceByteLength` | Number | Yes after upload | None | Integer source byte count; reject fractional values |
| `I2SPAnchorImmichId` | Single line text | Yes after upload | Not initially indexed | First Immich asset that caused the physical file to be stored; informational, not unique |
| `I2SPVerifiedUtc` | Date and time | No | None | Remains null until byte length and SHA-256 verification succeeds |

`I2SPAnchorImmichId` is not an initial query key: asset lookup belongs in Photo
Metadata, while byte lookup uses `I2SPContentSha256`. It therefore does not
justify an index initially. Add that index only if measured reconciliation
queries require it and the change is reviewed.

### Deterministic filename and extension collision policy

The intended filename is `<sha256>.<canonical-extension>`. The extension is
derived from validated content/media identification, not from the source name.
The mapping from an identified media format to one canonical lowercase extension
must be fixed and versioned before import. Thus, byte-identical sources named
with different extensions resolve to the same filename and one physical file.

If the SHA-256 already exists, the existing Photos item is reused after its hash
and byte length are verified, regardless of a later source filename or extension.
If a pre-existing filename points to different bytes or its identity fields do
not agree, synchronization stops with `Conflict`; it never overwrites, renames,
or creates a second physical copy automatically. Recognition of every supported
image/video format and the canonical extension table remain pending synthetic
tests in Task 2B.2.

## Photo Metadata list

Exactly one Asset item represents each Immich asset, including when multiple
assets point to one Photos item. MetadataChunk items are exceptional continuations
of a complete serialized metadata envelope, not property records.

### Identity and file relationship

| Internal name | SharePoint type | Asset use | MetadataChunk use | Index/uniqueness |
| --- | --- | --- | --- | --- |
| `I2SPRecordKey` | Single line text | Required | Required | Unique and indexed |
| `I2SPRecordKind` | Choice: `Asset`, `MetadataChunk` | `Asset` | `MetadataChunk` | Not initially indexed |
| `I2SPImmichAssetId` | Single line text | Required | Required | Indexed |
| `I2SPContentSha256` | Single line text | Required | May repeat for integrity | Indexed |
| `I2SPPhotoLookup` | Single-value SharePoint Lookup | Required after file creation | Null | Native lookup to Photos; not used to bypass thresholds |
| `I2SPPhotoItemId` | Number | Required after file creation | Null | Not initially indexed |
| `I2SPPhotoUniqueId` | Single line text | Required after file creation | Null | Not initially indexed |
| `I2SPBucket` | Single line text | Required | Required | Indexed |

`I2SPPhotoLookup` is a genuine single-value SharePoint Lookup whose target is the
Photos library in the same site. Its displayed source field is
`I2SPContentSha256`; the stored relationship references the Photos target list
item ID. It is not replaced by a Number or Hyperlink column. The Asset also keeps
the SHA-256, numeric item ID, and SharePoint file `UniqueId` as independent
integrity checks. All four values must resolve to the same Photos item before an
Asset can become `Complete`.

Microsoft documents that lookup columns create relationships to items in another
list or library and that the displayed source column can be selected. The exact
field-schema/PnP.PowerShell operation for targeting the Photos library and using
its custom SHA-256 field as the display field must still be proven in a synthetic
site before provisioning is approved.

MetadataChunk items do not populate the lookup, numeric Photos ID, or file
UniqueId. They associate with their primary Asset through
`I2SPImmichAssetId`, `I2SPMetadataRevision`, and their deterministic record key.

### Searchable photographic projections

These columns are populated only on the primary Asset item. Null is valid when
the source has no corresponding information.

| Internal name | SharePoint type | Purpose |
| --- | --- | --- |
| `I2SPOriginalFileName` | Multiple lines text | Original source filename without using it as archive identity |
| `I2SPMediaType` | Choice: `Image`, `Video` | Searchable media category |
| `I2SPDateTakenUtc` | Date and time | Normalized searchable capture time, when unambiguous |
| `I2SPDateTakenRaw` | Single line text | Raw selected capture-time representation |
| `I2SPCameraMake` | Single line text | Searchable camera manufacturer projection |
| `I2SPCameraModel` | Single line text | Searchable camera model projection |
| `I2SPLensModel` | Single line text | Searchable lens model projection |
| `I2SPWidth` | Number | Integer pixel width |
| `I2SPHeight` | Number | Integer pixel height |
| `I2SPDurationMs` | Number | Integer duration in milliseconds; normally null for images |
| `I2SPGpsLatitude` | Number | Latitude projection |
| `I2SPGpsLongitude` | Number | Longitude projection |
| `I2SPGpsAltitude` | Number | Altitude projection |
| `I2SPCountry` | Single line text | Searchable country projection |
| `I2SPState` | Single line text | Searchable state/region projection |
| `I2SPCity` | Single line text | Searchable city projection |
| `I2SPDescription` | Multiple lines text | Description projection |
| `I2SPAlbumNames` | Multiple lines text | Human-readable album-name projection |
| `I2SPIsFavorite` | Yes/No | Favorite-state projection |

These typed columns make common photo attributes directly searchable and
filterable where their SharePoint types support those operations. They are
projections, not the authoritative metadata representation. Projection rules
must specify source precedence, but disagreement is never erased: every distinct
source value and its provenance remain in the complete metadata envelope.

### Complete metadata and synchronization

| Internal name | SharePoint type | Asset use | MetadataChunk use |
| --- | --- | --- | --- |
| `I2SPMetadataSha256` | Single line text | Required when a payload exists; hash of complete serialized envelope | Same complete-envelope hash |
| `I2SPMetadataRevision` | Single line text | Required when a payload exists | Required; identifies the same specific revision as its Asset |
| `I2SPMetadataEncoding` | Single line text | Required when a payload exists | Required; identical across one revision |
| `I2SPPayloadChunk` | Multiple lines plain text | Initial payload chunk | Continuation payload chunk |
| `I2SPChunkIndex` | Number | Integer `0` when a payload exists | Required non-negative integer |
| `I2SPChunkCount` | Number | Total expected item count for this envelope | Same expected count on every chunk |
| `I2SPSyncState` | Choice: `Pending`, `Complete`, `Conflict`, `Failed`, `Overflow` | Required | Null; status belongs to the Asset |
| `I2SPLastSyncUtc` | Date and time | Set only after successful verification | Null |

The Asset contains chunk index zero. Additional MetadataChunk items are allowed
only when the complete serialized envelope exceeds the verified capacity of the
primary item. Chunking is not designed or implemented in this task. No safe
SharePoint chunk size is assumed: effective plain-text field capacity, item
update behavior, encoding expansion, and API behavior are pending controlled
compatibility tests.

`Pending` means synchronization is incomplete. `Complete` requires a verified
file relationship and verified complete envelope. `Conflict` records an identity
or destination disagreement that must not be resolved by overwrite. `Failed`
records a retryable or reviewed operational failure. `Overflow` means the
envelope could not be stored completely within validated limits. Failure details
must not include metadata values or other personal information in logs.

## Versioned metadata envelope contract

The payload is one versioned logical envelope per Immich asset and metadata
revision. Its intended structure contains these top-level domains:

| Domain | Required content |
| --- | --- |
| Envelope identity | Schema version, metadata revision, encoding identifier, Immich asset ID, original-byte SHA-256 |
| Immich asset | Complete asset information obtained through the approved read-only extraction paths |
| Immich metadata | Database/API metadata and custom metadata, separated by source and extraction path |
| Original-file metadata | EXIF, IPTC, XMP, manufacturer-specific tags, and their namespaces |
| Media metadata | Video, audio, container, stream, and QuickTime information |
| Albums | Album identifiers, names, memberships, and source relationships |
| Provenance | Extractor names and versions, source category, extraction time, and transformations applied only to the serialized representation |

The eventual serialization contract must preserve:

- arrays and their order;
- empty arrays and empty objects;
- original scalar data types rather than coercing everything to text;
- raw timestamp representations alongside any normalized projection;
- metadata namespaces and source boundaries;
- duplicate tag occurrences and their order;
- binary values where the approved extractor can obtain them.

The encoding must be deterministic so `I2SPMetadataSha256` can identify an exact
serialized envelope. The schema version and encoding identifier must make future
readers able to select the correct decoder. The choice of serialization format,
canonicalization rules, binary representation, and chunk boundaries belongs to
Task 2B.2.

The envelope is intended to preserve complete metadata, but it must **not** be
described as lossless until synthetic round-trip tests cover all supported types,
empty structures, duplicate tags, namespaces, raw timestamps, binary values,
and multi-chunk reconstruction. A typed SharePoint column is only a searchable
projection of this envelope, never its authoritative replacement.

## MetadataChunk requirements

- MetadataChunk items are used only for oversized metadata envelopes and remain
  in the Photo Metadata list.
- They never represent ordinary individual EXIF, IPTC, XMP, or other fields.
- They must not appear in normal photo-browsing views.
- Every chunk belongs to one Immich asset and one specific metadata revision.
- Every chunk has a deterministic unique `I2SPRecordKey` derived from record
  kind, Immich asset ID, metadata revision, and chunk index using the versioned
  key contract defined in Task 2B.2.
- `I2SPChunkIndex` records order and `I2SPChunkCount` records the expected total,
  including chunk zero stored on the Asset.
- After ordered reconstruction, SHA-256 of the complete serialized envelope must
  equal `I2SPMetadataSha256` on the Asset and every MetadataChunk item.
- The Asset must never become `Complete` until every expected chunk and the file
  relationship have been verified.
- During a metadata update, the previous complete envelope must remain
  recoverable until the replacement revision is fully stored and verified.
  Previous revision chunks must not be deleted early.

The serialization, chunk-size selection, record-key encoding, write ordering,
rollback/recovery mechanism, and transactional update behavior belong to Task
2B.2. In particular, recovery of a previous single-item envelope during an
update requires a tested design; SharePoint version history is a possible
platform facility, not an assumed solution in this specification.

## Duplicate, update, and conflict policy

| Observation | Photos action | Photo Metadata action |
| --- | --- | --- |
| New Immich ID and new SHA-256 | Upload original bytes once; do not modify them | Create one Asset; add MetadataChunk items only if capacity tests require them |
| Existing Immich ID and same SHA-256, same metadata hash | Do not upload | No payload rewrite; verify current relationship and state |
| Existing Immich ID and same SHA-256, changed metadata | Do not upload | Create and verify a replacement metadata revision while keeping the previous complete revision recoverable |
| New Immich ID and existing SHA-256 | Reuse verified Photos item | Create a distinct Asset linked to the same Photos item |
| Existing Immich ID and different SHA-256 | Never overwrite or silently relink | Set Asset to `Conflict`; require review |
| Existing filename with different bytes or inconsistent identity fields | Never overwrite | Set Asset to `Conflict`; require review |
| Partial metadata write | No file action | Resume by deterministic RecordKey; keep Asset non-complete until all expected items verify |

Uniqueness of `Photos.I2SPContentSha256` enforces one physical byte object.
Uniqueness of `Photo Metadata.I2SPRecordKey` makes Asset and MetadataChunk writes
idempotent. Multiple Asset items may intentionally contain the same content hash
and native lookup value.

## Indexing and views for 17,818 active assets

The known planning count is 17,818 active assets, already above SharePoint's
approximately 5,000-item list-view threshold before any MetadataChunk items are
added. Indexes must be created before bulk import. Microsoft documents that an
indexed lookup can improve some operations but does not bypass the list-view
threshold; `I2SPPhotoLookup` is therefore not the threshold partition key.

### Initial index priority

Create only these indexes initially, in this order:

1. `I2SPRecordKey` — unique index for idempotent writes.
2. `I2SPImmichAssetId` — retrieve the primary item and any chunks for one asset.
3. `I2SPContentSha256` — find all Immich assets sharing one physical file.
4. `I2SPBucket` — selective first filter for views and paged reconciliation.
5. `I2SPDateTakenUtc` — date-range browsing within a bucket when populated.
6. `I2SPMediaType` — media filtering within a bucket.
7. `I2SPSyncState` — bounded operational queues within a bucket.

No initial indexes are proposed for `I2SPRecordKind`, the lookup, numeric Photos
ID, file UniqueId, metadata revision, or chunk numbers. Additions require measured
query evidence and review; unnecessary indexes add write and administration cost.

`I2SPBucket` is the first two lowercase hexadecimal characters of SHA-256 applied
to the Immich asset ID, yielding 256 possible values. Asset and MetadataChunk
items for the same Immich asset use the same bucket. This is a proposed
partitioning function, not a claim of uniform real-world distribution. Before
bulk import, measure bucket counts with synthetic tooling against approved source
identifiers without committing or logging them. Validate the largest bucket,
including projected MetadataChunk growth, against the tenant's effective
threshold and revise the view plan if any bucket is insufficiently selective.

### View strategy

Normal photo browsing uses bucket-scoped Asset views. The first filter is
indexed and selective:

1. `I2SPBucket` equals one selected bucket; then
2. `I2SPRecordKind` equals `Asset`.

This excludes MetadataChunk items without relying on the unselective
`RecordKind = Asset` predicate alone. Optional filters such as date taken, media
type, or sync state are applied only after the bucket predicate and use the
listed indexes where appropriate. Views show only necessary columns, use a page
limit, and avoid unbounded totals, grouping, and sorting. A single all-assets
default view is prohibited at this collection size.

Chunk-management queries likewise start with an indexed bucket or exact indexed
Immich asset ID before filtering for `MetadataChunk`. Operational code must use
paging and must not infer that paging permits an otherwise threshold-violating
query. Every view/query shape, including its filter order and lookup projection,
requires testing in a synthetic SharePoint site at and above expected scale.

## Provisioning approach

Provisioning remains a separate, reviewed PnP.PowerShell activity and is not part
of this task.

1. Define the two containers and exact columns in a versioned, source-controlled
   schema manifest with fixed field GUIDs and no tenant settings or credentials.
2. Default to plan/dry-run and report compatible, missing, and incompatible
   schema without printing private values.
3. After explicit deployment approval, create or validate only Photos and Photo
   Metadata. Never create a fallback container.
4. Create fields, native lookup relationship, uniqueness, and the seven initial
   indexes before loading data; create only threshold-safe views.
5. Re-read and compare the applied schema. Fail on incompatible drift rather
   than deleting fields, changing populated types, weakening uniqueness, or
   recreating containers automatically.

Microsoft documents list relationships and field schema, while PnP.PowerShell
documents relevant list and field commands. Exact provisioning commands,
permissions, authentication, and compatibility behavior must be designed and
tested later; no provisioning behavior is claimed as verified here.

## Verified platform behavior and unresolved validation

### Documented platform behavior

- SharePoint supports relationships between lists/libraries through Lookup
  columns, with a selected source column displayed for the related item.
- Lookup relationships identify target items, while additional projected values
  are display data; this design independently stores item ID, file UniqueId, and
  SHA-256 for integrity checks.
- An indexed Lookup column must not be used to avoid the list-view threshold.
- Single line text, Choice, Number, Date and time, and Yes/No columns support
  indexing; Multiple lines text does not.
- SharePoint permits at most 20 indexes per list or library according to current
  Microsoft guidance, so indexes should be limited to measured query needs.

### Validation required before provisioning or import

- Confirm in a synthetic SharePoint Online site that a Photo Metadata lookup can
  target the Photos library and display custom field `I2SPContentSha256`, using
  the intended PnP.PowerShell version and fixed schema IDs.
- Confirm native lookup read/write representations across the selected API and
  PnP.PowerShell paths, including item ID and displayed SHA-256 behavior.
- Measure actual bucket distribution and projected MetadataChunk counts; prove
  every operational view/query remains below the effective threshold.
- Test all view filters, filter ordering, paging, sorting, and selected columns
  at and above the expected 17,818 Asset items.
- Determine effective Multiple lines text and complete-item capacities through
  boundary tests. No chunk size is approved yet.
- Define and round-trip test canonical serialization, type fidelity, namespaces,
  duplicate tags, raw timestamps, empty structures, arrays, binary values,
  encoding expansion, and multi-chunk reconstruction.
- Define and test deterministic key encoding, canonical media extensions,
  byte-identity verification, metadata revision replacement, rollback, retry,
  checkpoint recovery, and preservation of the previous complete revision.
- Verify integer and floating-point behavior for byte lengths, dimensions,
  durations, coordinates, item IDs, and all chosen API representations.
- Validate column required/null behavior, unique-field behavior, list versioning
  if considered for recovery, library/list permissions, tenant throttling, file
  type/path restrictions, and effective service limits.

## Authoritative references

- [Create list relationships by using lookup columns](https://support.microsoft.com/en-us/sharepoint/lists/data-and-lists/create-list-relationships-by-using-lookup-columns)
- [Field element schema](https://learn.microsoft.com/en-us/sharepoint/dev/schema/field-element-list)
- [Add an index to a list or library column](https://support.microsoft.com/en-us/sharepoint/data-and-lists/add-an-index-to-a-list-or-library-column)
- [Working with the List View Threshold](https://support.microsoft.com/en-us/sharepoint/data-and-lists/working-with-the-list-view-threshold-limit-for-all-versions-of-sharepoint)
- [SharePoint limits](https://learn.microsoft.com/en-us/office365/servicedescriptions/sharepoint-online-service-description/sharepoint-online-limits)
- [List and library column types and options](https://support.microsoft.com/en-us/sharepoint/lists/data-and-lists/list-and-library-column-types-and-options)
- [PnP.PowerShell `New-PnPList`](https://pnp.github.io/powershell/cmdlets/New-PnPList.html)
- [PnP.PowerShell `Add-PnPField`](https://pnp.github.io/powershell/cmdlets/Add-PnPField.html)
- [PnP.PowerShell `Set-PnPField`](https://pnp.github.io/powershell/cmdlets/Set-PnPField.html)
