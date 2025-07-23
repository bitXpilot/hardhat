//npx hardhat run scripts/deploy.ts --network sepolia
import { ethers } from "hardhat"
import * as dotenv from "dotenv"

dotenv.config()

async function main() {
  const LSRWAExpress = await ethers.getContractFactory("LSRWAExpress")
  const contract = await LSRWAExpress.deploy(process.env.USDC_ADDRESS || "", process.env.TOKEN_ADDRESS || "")
  await contract.waitForDeployment()
  console.log("Deployed to:", await contract.getAddress())
}

main().catch((error) => {
  console.error(error)
  process.exitCode = 1
})
