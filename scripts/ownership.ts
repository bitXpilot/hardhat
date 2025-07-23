//npx hardhat run scripts/ownership.ts --network sepolia
import { ethers } from "hardhat"
import * as dotenv from "dotenv"

dotenv.config()

async function main() {
  const contract = await ethers.getContractAt("LSRWAExpress", process.env.CONTRACT_ADDRESS || "")
  const tx = await contract.transferOwnership(process.env.OWNER_ADDRESS || "")
  await tx.wait()
  console.log("Changed ownership to:", await contract.getAddress())
}

main().catch((error) => {
  console.error(error)
  process.exitCode = 1
})
