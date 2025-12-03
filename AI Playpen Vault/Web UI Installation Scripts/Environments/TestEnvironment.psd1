@{
    Name     = "Test"
    BasePath = "C:\inetpub\wwwroot\RatabaseWebUITest"

    Client = @{
        AppPoolName = "pl-ratabase-webui-test-sandbox.lmig.com"
        HostUrl     = "pl-ratabase-webui-test-sandbox.lmig.com"
        LogPath     = "D:\Scripts\Logs\silent_Client_Test.log"
        ClientEmail = "ratingconsultants @libertymutual.com"
        GridLicense = "TEMP_GRID_LICENSE"
        DatasetName = "Test"
        ClientName  = "Test Sandbox"
    }

    Api = @{
        InstallLocation64 = "C:\inetpub\wwwroot\RatabaseWebUITest\RatabasePB"
        InstallLocation32 = "C:\inetpub\wwwroot\RatabaseWebUITest\RatabasePB"
        WebAppName64      = "RatabaseX64"
        WebAppName32      = "RatabaseX86"
        AppPoolName64     = "API_Test_64-bitAppPool"
        AppPoolName32     = "API_Test_32-bitAppPool"
        LogFolder         = "D:\CGI\RatabaseTestPBAPI"
        DocFolder         = "D:\CGI\RatabaseTestPBAPI\Documents"
        PerFolder         = "D:\CGI\RatabaseTestPBAPI\FileUpload"
        LogSize           = 10737418240
        DB = @{
            Dataset   = "Test"
            ServerName = "vmpid-ykr27yyx.lm.lmig.com"
            Username   = "rb_webui"
            Password   = "PUT_DB_PASSWORD_HERE"
            Dev        = "AutoGrs01"
            Test       = "AutoGrsTest"
            Personal   = "AutoGrsPersonal"
            Import     = "AutoGrsImport"
            Odd        = " "
        }
        LogPath = "D:\Scripts\Logs\silent_API_Test.log"
    }
}