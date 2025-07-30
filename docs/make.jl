using Appose
using Documenter

DocMeta.setdocmeta!(Appose, :DocTestSetup, :(using Appose); recursive=true)

makedocs(;
    modules=[Appose],
    authors="Mark Kittisopikul <markkitt@gmail.com> and contributors",
    sitename="Appose.jl",
    format=Documenter.HTML(;
        canonical="https://apposed.github.io/Appose.jl",
        edit_link="main",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/apposed/Appose.jl",
    devbranch="main",
)
