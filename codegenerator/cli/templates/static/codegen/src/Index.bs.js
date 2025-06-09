#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");

console.log("🔄 Migrating to envio@2.22.0 or later...");

// Function to update package.json
function updatePackageJson() {
  try {
    // Look for package.json in current directory and parent directories
    let packageJsonPath = null;
    let currentDir = process.cwd();

    // Search up the directory tree for package.json
    while (currentDir !== path.dirname(currentDir)) {
      const potentialPath = path.join(currentDir, "package.json");
      if (fs.existsSync(potentialPath)) {
        packageJsonPath = potentialPath;
        break;
      }
      currentDir = path.dirname(currentDir);
    }

    if (!packageJsonPath) {
      console.log("❌ Could not find package.json file");
      return false;
    }

    console.log(`📦 Found package.json at: ${packageJsonPath}`);

    // Read and parse package.json
    const packageJsonContent = fs.readFileSync(packageJsonPath, "utf8");
    const packageJson = JSON.parse(packageJsonContent);

    // Check if scripts section exists
    if (!packageJson.scripts) {
      console.log("⚠️  No scripts section found in package.json");
      return false;
    }

    // Update the start script
    let updated = false;
    if (packageJson.scripts.start) {
      let originalScript = packageJson.scripts.start;
      let newScript = originalScript;

      // Replace ts-node generated/src/Index.bs.js with envio start
      newScript = newScript.replace(
        /ts-node\s+generated\/src\/Index\.bs\.js/g,
        "envio start"
      );

      // Replace node generated/src/Index.bs.js with envio start
      newScript = newScript.replace(
        /node\s+generated\/src\/Index\.bs\.js/g,
        "envio start"
      );

      if (newScript !== originalScript) {
        console.log("🔧 Updating start script...");
        console.log(`   From: ${originalScript}`);
        console.log(`   To:   ${newScript}`);
        packageJson.scripts.start = newScript;
        updated = true;
      }
    }

    if (updated) {
      // Write back the updated package.json
      fs.writeFileSync(
        packageJsonPath,
        JSON.stringify(packageJson, null, 2) + "\n"
      );
      console.log("✅ Package.json updated successfully!");
      return true;
    } else {
      console.log("ℹ️  No scripts found that need updating");
      return false;
    }
  } catch (error) {
    console.error("❌ Error updating package.json:", error.message);
    return false;
  }
}

// Function to run envio start
function runEnvioStart() {
  console.log("🚀 Starting Envio...");

  const envioProcess = spawn("envio", ["start"], {
    stdio: "inherit",
    cwd: process.cwd(),
  });

  envioProcess.on("error", (error) => {
    if (error.code === "ENOENT") {
      console.error(
        '❌ Error: "envio" command not found. Please make sure Envio CLI is installed.'
      );
    } else {
      console.error("❌ Error running envio start:", error.message);
    }
    process.exit(1);
  });

  envioProcess.on("close", (code) => {
    if (code !== 0) {
      console.log(`❌ Envio start exited with code ${code}`);
      process.exit(code);
    }
  });
}

// Main execution
console.log("📋 Migration steps:");
console.log("  1. Update package.json scripts");
console.log("  2. Run envio start");
console.log("");

// Update package.json
const packageUpdated = updatePackageJson();

if (packageUpdated) {
  console.log("");
  console.log("🎉 Migration completed! Your package.json has been updated.");
  console.log(
    '   From now on, you can use "npm start" or "envio start" directly.'
  );
  console.log("");
}

// Run envio start
runEnvioStart();
