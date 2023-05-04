@react.component
let make = (~src) => {
  <section className="h-60-percent-screen my-4 relative flex justify-center items-center">
    <div className="w-full max-w-5xl flex justify-center items-center">
      <Next.Image src layout=#fill objectFit="contain" />
    </div>
  </section>
}
