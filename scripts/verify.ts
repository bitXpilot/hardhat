// scripts/verify.ts
import { run } from "hardhat"
import * as dotenv from "dotenv"

dotenv.config()

async function main() {
  const contractAddress = process.env.CONTRACT_ADDRESS || ""
  const constructorArgs = [
    process.env.USDC_ADDRESS || "",
    process.env.TOKEN_ADDRESS || ""
  ]

  await run("verify:verify", {
    address: contractAddress,
    constructorArguments: constructorArgs,
  })
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
