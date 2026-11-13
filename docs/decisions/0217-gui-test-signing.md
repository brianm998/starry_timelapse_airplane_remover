# 0217: sign GUI test builds with Apple Development, manually

macOS keys the removable-volume permission to code identity; ad hoc changes every build. Manual signing with the team identity gives a stable designated requirement and stays headless. `-allowProvisioningUpdates` was rejected because it can open an account dialog. `STAR_TEST_SIGN_IDENTITY=-` restores ad hoc.
