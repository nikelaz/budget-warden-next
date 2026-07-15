/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 */

use std::fs::{self, File};
use std::io::{self, Write};
use std::path::Path;

pub fn write_file_atomic(path: &str, contents: &[u8]) -> io::Result<()> {
    let target = Path::new(path);

    let parent = target.parent().ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, "Path has no parent directory")
    })?;

    let file_name = target.file_name().ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, "Path has no file name")
    })?;

    let temp_path = parent.join(format!(
        ".{}.tmp",
        file_name.to_string_lossy()
    ));

    {
        let mut temp_file = File::create(&temp_path)?;
        temp_file.write_all(contents)?;

        // Flush Rust's userspace buffer.
        temp_file.flush()?;

        // Ask the OS to persist the file contents.
        temp_file.sync_all()?;
    }

    fs::rename(&temp_path, target)?;

    Ok(())
}
