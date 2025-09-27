using SyncB
using Documenter

DocMeta.setdocmeta!(SyncB, :DocTestSetup, :(using SyncB); recursive=true)

makedocs(;
    modules=[SyncB],
    authors="jheras <jherasm@gmail.com> and contributors",
    sitename="SyncB.jl",
    format=Documenter.HTML(;
        canonical="https://alxg78.github.io/SyncB.jl",
        edit_link="main",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/alxg78/SyncB.jl",
    devbranch="main",
)
