
const format_mod = @import("format.zig");

pub const BACKUP_MAGIC = format_mod.BACKUP_MAGIC;
pub const BACKUP_VERSION = format_mod.BACKUP_VERSION;
pub const BACKUP_HEADER_SIZE = format_mod.BACKUP_HEADER_SIZE;
pub const SECTION_HEADER_FIXED_SIZE = format_mod.SECTION_HEADER_FIXED_SIZE;

pub const BackupHeader = format_mod.BackupHeader;
pub const SectionHeader = format_mod.SectionHeader;
pub const What = format_mod.What;
pub const BackupMetadata = format_mod.BackupMetadata;
pub const FormatError = format_mod.FormatError;

pub const writeHeader = format_mod.writeHeader;
pub const readHeader = format_mod.readHeader;
pub const writeSectionHeader = format_mod.writeSectionHeader;
pub const readSectionHeader = format_mod.readSectionHeader;

pub const createServiceArchive = @import("inner.zig").createServiceArchive;
pub const restoreInnerArchive = @import("inner.zig").restoreInnerArchive;

pub const container = @import("container/root.zig");
pub const ContainerFormat = container.ContainerFormat;

pub const createAppArchive = @import("orchestrate.zig").createAppArchive;
pub const restoreAppArchive = @import("orchestrate.zig").restoreAppArchive;
pub const ServiceQuiesce = @import("orchestrate.zig").ServiceQuiesce;
pub const PlistCheckCallback = @import("orchestrate.zig").PlistCheckCallback;
pub const BootstrapCallback = @import("orchestrate.zig").BootstrapCallback;
pub const CreateOptions = @import("orchestrate.zig").CreateOptions;
pub const CreateResult = @import("orchestrate.zig").CreateResult;
pub const RestoreOptions = @import("orchestrate.zig").RestoreOptions;
pub const RestoreResult = @import("orchestrate.zig").RestoreResult;

pub const listBackups = @import("housekeeping.zig").listBackups;
pub const cleanupOldBackups = @import("housekeeping.zig").cleanupOldBackups;
pub const freeBackupList = @import("housekeeping.zig").freeBackupList;
pub const BackupEntry = @import("housekeeping.zig").BackupEntry;

test {
    _ = @import("format.zig");
    _ = @import("inner.zig");
    _ = @import("container/root.zig");
    _ = @import("orchestrate.zig");
    _ = @import("housekeeping.zig");
}
