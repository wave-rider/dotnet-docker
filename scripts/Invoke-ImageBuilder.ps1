#!/usr/bin/env pwsh

<#
.SYNOPSIS
Executes ImageBuilder with the specified args.

.PARAMETER ImageBuilderArgs
The args to pass to ImageBuilder.

.PARAMETER DockerRunOptions
Additional options to pass to the "docker run" command.

.PARAMETER ReuseImageBuilderImage
Indicates that a previously built ImageBuilder image is presumed to exist locally and that 
it should be used for this execution of the script.  This allows some optimization when
multiple calls are being made to this script that don't require a fresh image (i.e. the
repo contents in the image don't need to be or should not be updated with each call to
this script).

.PARAMETER OnCommandExecuted
A ScriptBlock that will be invoked after the ImageBuilder command has been executed.
This allows the caller to execute extra logic in the context of the ImageBuilder while
its container is still running.
The ScriptBlock is passed the following argument values:
    1. Container name
#>
[cmdletbinding()]
param(
    [string]
    $ImageBuilderArgs,

    [string]
    $DockerRunOptions,

    [switch]
    $ReuseImageBuilderImage,

    [scriptblock]
    $OnCommandExecuted
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Log {
    param ([string] $Message)

    Write-Output $Message
}

function Exec {
    param ([string] $Cmd)

    Log "Executing: '$Cmd'"
    Invoke-Expression $Cmd
    if ($LASTEXITCODE -ne 0) {
        throw "Failed: '$Cmd'"
    }
}

$imageBuilderContainerName = "ImageBuilder-$(Get-Date -Format yyyyMMddhhmmss)"
$containerCreated = $false

pushd $PSScriptRoot/../
try {

    $imageNames = ./Get-ImageNames.ps1

    # If we need to execute the OnCommandExcecuted callback, defer the removal of the container until the end of the script.
    $deferContainerRemoval = ($null -ne $OnCommandExecuted)

    $activeOS = docker version -f "{{ .Server.Os }}"
    if ($activeOS -eq "linux") {
        # On Linux, ImageBuilder is run within a container.
        $imageBuilderImageName = "microsoft-dotnet-imagebuilder-withrepo"
        if ($ReuseImageBuilderImage -ne $True) {
            ./scripts/Invoke-WithRetry "docker pull $($imageNames.ImageBuilderLinux)"
            Exec "docker build -t $imageBuilderImageName --build-arg IMAGE=$($imageNames.ImageBuilderLinux) -f ./scripts/Dockerfile.WithRepo ."
        }

        $dockerRunOptions = "$DockerRunOptions --name $imageBuilderContainerName -v /var/run/docker.sock:/var/run/docker.sock"

        if (-not $deferContainerRemoval) {
            $dockerRunOptions += " --rm"
        }

        $imageBuilderCmd = "docker run $dockerRunOptions $imageBuilderImageName"
        $containerCreated = $true
    }
    else {
        # On Windows, ImageBuilder is run locally due to limitations with running Docker client within a container.
        $imageBuilderFolder = ".Microsoft.DotNet.ImageBuilder"
        $imageBuilderCmd = [System.IO.Path]::Combine($imageBuilderFolder, "Microsoft.DotNet.ImageBuilder.exe")
        if (-not (Test-Path -Path "$imageBuilderCmd" -PathType Leaf)) {
            ./scripts/Invoke-WithRetry "docker pull $($imageNames.ImageBuilderWindows)"
            Exec "docker create --name $imageBuilderContainerName $($imageNames.ImageBuilderWindows)"
            $containerCreated = $true

            if (Test-Path -Path $imageBuilderFolder) {
                Remove-Item -Recurse -Force -Path $imageBuilderFolder
            }

            Exec "docker cp ${imageBuilderContainerName}:/image-builder $imageBuilderFolder"
        }
    }

    Exec "$imageBuilderCmd $ImageBuilderArgs"

    if ($OnCommandExecuted) {
        Invoke-Command $OnCommandExecuted -ArgumentList $imageBuilderContainerName
    }
}
finally {
    if ($deferContainerRemoval -and $containerCreated) {
        Exec "docker container rm -f $imageBuilderContainerName"
    }
    
    popd
}
