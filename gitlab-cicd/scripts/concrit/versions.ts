import * as fs from "fs";
import * as path from "path";
import * as crypto from "crypto";

type MasterDataFile = {
  fileName: string;
  version: string;
};

type MasterDataVersion = {
  version: string;
  dataFiles: MasterDataFile[];
};

/**
 * Calculate SHA-256 checksum of a file
 */
const calculateFileChecksum = (filePath: string): string =>
  crypto.createHash("sha256").update(fs.readFileSync(filePath)).digest("hex");

/**
 * Load files from a specified directory and calculate checksums in parallel
 */
const loadFiles = async (
  directory: string,
  extension: string,
  filter?: (file: string) => boolean
): Promise<MasterDataFile[]> => {
  try {
    const files = fs
      .readdirSync(path.join(__dirname, "..", directory))
      .filter((file) => path.extname(file) === extension)
      .filter(filter || (() => true));

    const results = await Promise.all(
      files.map(async (file) => ({
        fileName: path.basename(file, extension),
        version: calculateFileChecksum(
          path.join(__dirname, "..", directory, file)
        ),
      }))
    );

    return results;
  } catch (error) {
    throw new Error(
      `Failed to load files from ${directory}: ${
        error instanceof Error ? error.message : String(error)
      }`
    );
  }
};

/**
 * Generate and save the master data version file
 */
const generateDataVersion = async (versions?: string): Promise<void> => {
  const [jsonFiles, csvFiles] = await Promise.all([
    loadFiles("json", ".json"),
    loadFiles("csv", ".csv", (file) => file === "Language.csv"),
  ]);

  const masterDataVersion: MasterDataVersion = {
    version: versions || Math.floor(Date.now() / 1000).toString(),
    dataFiles: [...jsonFiles, ...csvFiles],
  };

  const filePath = path.join(__dirname, "..", "version", "DataVersion.json");
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, JSON.stringify(masterDataVersion), "utf8");
};

// Extract --version from command line arguments and execute
const versionArg = process.argv.find(
  (arg, i) => process.argv[i - 1] === "version"
);

generateDataVersion(versionArg).catch(console.error);
